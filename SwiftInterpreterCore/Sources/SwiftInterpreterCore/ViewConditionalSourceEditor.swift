import Foundation
import SwiftParser
import SwiftSyntax

/// Finds and replaces one view-builder `if` expression while preserving the
/// surrounding Swift source. The kernel repeats this operation after each
/// selected branch so nested conditions are discovered lazily.
struct ViewConditionalSourceEditor {
    func firstConditional(in source: String) throws -> ViewConditionalSite? {
        let syntaxTree = Parser.parse(source: source)
        guard !syntaxTree.hasError else {
            throw RuntimeViewLoweringError.malformedSyntax
        }
        guard syntaxTree.statements.count == 1 else {
            throw RuntimeViewLoweringError.expectedSingleExpression
        }

        let visitor = FirstConditionalVisitor()
        visitor.walk(syntaxTree)
        guard let conditional = visitor.conditional else { return nil }
        let clauses = try viewConditionalClauses(in: conditional.conditions)
        let bindings = clauses.flatMap { clause -> [ViewConditionalBinding] in
            switch clause {
            case .optionalBinding(let binding): return [binding]
            case .matchingPattern(let values): return values
            case .expression: return []
            }
        }
        let simpleConditionExpression: String?
        if conditional.conditions.count == 1,
           let condition = conditional.conditions.first,
           case .expression(let expression) = condition.condition {
            simpleConditionExpression = expression.trimmedDescription
        } else {
            simpleConditionExpression = nil
        }

        let falseBranchSource: String
        if let elseBody = conditional.elseBody {
            switch elseBody {
            case .codeBlock(let codeBlock):
                falseBranchSource = codeBlock.statements.description
            case .ifExpr(let nestedConditional):
                falseBranchSource = nestedConditional.trimmedDescription
            }
        } else {
            falseBranchSource = ""
        }

        return ViewConditionalSite(
            conditionExpression: simpleConditionExpression,
            conditionSource: viewConditionalConditionSource(conditional.conditions),
            clauses: clauses,
            bindings: bindings,
            trueBranchSource: conditional.body.statements.description,
            falseBranchSource: falseBranchSource,
            startUTF8Offset: conditional.positionAfterSkippingLeadingTrivia.utf8Offset,
            endUTF8Offset: conditional.endPositionBeforeTrailingTrivia.utf8Offset
        )
    }

    func replacing(
        _ site: ViewConditionalSite,
        in source: String,
        selecting condition: Bool
    ) throws -> String {
        let replacement = replacementText(for: site, selecting: condition)
        let sourceBytes = Array(source.utf8)
        guard site.startUTF8Offset <= site.endUTF8Offset,
              site.endUTF8Offset <= sourceBytes.count else {
            throw RuntimeViewLoweringError.malformedSyntax
        }

        var rewrittenBytes = sourceBytes
        rewrittenBytes.replaceSubrange(
            site.startUTF8Offset..<site.endUTF8Offset,
            with: replacement.utf8
        )
        return String(decoding: rewrittenBytes, as: UTF8.self)
    }

    func replacementText(for site: ViewConditionalSite, selecting condition: Bool) -> String {
        let branchSource = condition ? site.trueBranchSource : site.falseBranchSource
        let contents = branchSource.trimmingCharacters(in: .whitespacesAndNewlines)
        return contents.isEmpty ? "EmptyView()" : "Group { \(contents) }"
    }
}

func viewBuilderConditional(in item: CodeBlockItemSyntax.Item) -> IfExprSyntax? {
    let visitor = FirstConditionalVisitor()
    visitor.walk(item._syntaxNode)
    return visitor.conditional
}

func viewConditionalBindings(in conditions: ConditionElementListSyntax) throws -> [ViewConditionalBinding] {
    try viewConditionalClauses(in: conditions).flatMap { clause -> [ViewConditionalBinding] in
        switch clause {
        case .optionalBinding(let binding): return [binding]
        case .matchingPattern(let bindings): return bindings
        case .expression: return []
        }
    }
}

func viewConditionalClauses(in conditions: ConditionElementListSyntax) throws -> [ViewConditionalClause] {
    var clauses: [ViewConditionalClause] = []
    for condition in conditions {
        switch condition.condition {
        case .expression(let expression):
            clauses.append(.expression(expression.trimmedDescription))
        case .optionalBinding(let optionalBinding):
            guard optionalBinding.bindingSpecifier.text == "let",
                  let pattern = optionalBinding.pattern.as(IdentifierPatternSyntax.self) else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "optional binding must use a simple 'let' name: \(condition.trimmedDescription)"
                )
            }

            let name = pattern.identifier.text
            let initializer = optionalBinding.initializer?.value.trimmedDescription ?? name
            let typeAnnotation = optionalBinding.typeAnnotation?.trimmedDescription ?? ""
            clauses.append(.optionalBinding(
                ViewConditionalBinding(
                    name: name,
                    initializer: initializer,
                    typeAnnotation: typeAnnotation
                )
            ))
        case .matchingPattern(let match):
            let names = MatchingPatternNameVisitor()
            names.walk(match.pattern)
            let pattern = match.pattern.trimmedDescription
            let subject = match.initializer.value.trimmedDescription
            clauses.append(.matchingPattern(names.names.map { name in
                ViewConditionalBinding(
                    name: name,
                    initializer: subject,
                    typeAnnotation: "",
                    matchingPatternCondition: "case \(pattern) = \(subject)"
                )
            }))
        default:
            throw RuntimeViewLoweringError.unsupportedExpression(
                "conditional clause is not supported: \(condition.trimmedDescription)"
            )
        }
    }
    return clauses
}

enum ViewConditionalClause: Sendable, Hashable {
    case expression(String)
    case optionalBinding(ViewConditionalBinding)
    case matchingPattern([ViewConditionalBinding])
}

private final class MatchingPatternNameVisitor: SyntaxVisitor {
    private(set) var names: [String] = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        let name = node.identifier.text
        if name != "_" && !names.contains(name) { names.append(name) }
        return .skipChildren
    }
}

struct ViewConditionalBinding: Sendable, Hashable {
    let name: String
    let initializer: String
    let typeAnnotation: String
    let matchingPatternCondition: String?

    init(
        name: String,
        initializer: String,
        typeAnnotation: String,
        matchingPatternCondition: String? = nil
    ) {
        self.name = name
        self.initializer = initializer
        self.typeAnnotation = typeAnnotation
        self.matchingPatternCondition = matchingPatternCondition
    }

    var declaration: String {
        "let \(name)\(typeAnnotation) = \(initializer)"
    }
}

func viewConditionalConditionSource(_ conditions: ConditionElementListSyntax) -> String {
    conditions.description.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ViewConditionalSite: Sendable {
    let conditionExpression: String?
    let conditionSource: String
    let clauses: [ViewConditionalClause]
    let bindings: [ViewConditionalBinding]
    let trueBranchSource: String
    let falseBranchSource: String
    let startUTF8Offset: Int
    let endUTF8Offset: Int
}

private final class FirstConditionalVisitor: SyntaxVisitor {
    private(set) var conditional: IfExprSyntax?

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        if isInsideButtonActionClosure(node) || isInsideForEachClosure(node) {
            return .skipChildren
        }
        if conditional == nil {
            conditional = node
        }
        return .skipChildren
    }
}

private func isInsideForEachClosure(_ node: some SyntaxProtocol) -> Bool {
    var ancestor = node.parent
    while let current = ancestor {
        if let call = current.as(FunctionCallExprSyntax.self),
           call.calledExpression.trimmedDescription == "ForEach" {
            return true
        }
        ancestor = current.parent
    }
    return false
}
