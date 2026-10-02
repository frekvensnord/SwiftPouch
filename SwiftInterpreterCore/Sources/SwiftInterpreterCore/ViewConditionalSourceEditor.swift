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
        let bindings = try viewConditionalBindings(in: conditional.conditions)
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
    var bindings: [ViewConditionalBinding] = []
    for condition in conditions {
        let optionalBinding: OptionalBindingConditionSyntax
        switch condition.condition {
        case .expression:
            continue
        case .optionalBinding(let binding):
            optionalBinding = binding
        default:
            throw RuntimeViewLoweringError.unsupportedExpression(
                "conditional clause is not supported: \(condition.trimmedDescription)"
            )
        }

        guard optionalBinding.bindingSpecifier.text == "let",
              let pattern = optionalBinding.pattern.as(IdentifierPatternSyntax.self) else {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "optional binding must use a simple 'let' name: \(condition.trimmedDescription)"
            )
        }

        let name = pattern.identifier.text
        let initializer = optionalBinding.initializer?.value.trimmedDescription ?? name
        let typeAnnotation = optionalBinding.typeAnnotation?.trimmedDescription ?? ""
        bindings.append(
            ViewConditionalBinding(clause: "let \(name)\(typeAnnotation) = \(initializer)")
        )
    }
    return bindings
}

func viewConditionalConditionSource(_ conditions: ConditionElementListSyntax) -> String {
    conditions.description.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ViewConditionalSite: Sendable {
    let conditionExpression: String?
    let conditionSource: String
    let bindings: [ViewConditionalBinding]
    let trueBranchSource: String
    let falseBranchSource: String
    let startUTF8Offset: Int
    let endUTF8Offset: Int
}

struct ViewConditionalBinding: Sendable, Hashable {
    let clause: String
}

private final class FirstConditionalVisitor: SyntaxVisitor {
    private(set) var conditional: IfExprSyntax?

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        if isInsideButtonActionClosure(node) {
            return .skipChildren
        }
        if conditional == nil {
            conditional = node
        }
        return .skipChildren
    }
}
