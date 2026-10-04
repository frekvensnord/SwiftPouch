import Foundation
import SwiftParser
import SwiftSyntax

struct ViewStateDeclaration: Sendable {
    let name: String
    let storageName: String
    let initializer: String
}

struct ViewEnvironmentDeclaration: Sendable {
    let name: String
    let storageName: String
    let key: ViewEnvironmentKey
}

enum ViewEnvironmentKey: Equatable, Sendable {
    case scenePhase
    case dismiss
}

struct ExtractedViewBody: Sendable {
    let expression: String
    let stateDeclarations: [ViewStateDeclaration]
    let environmentDeclarations: [ViewEnvironmentDeclaration]
}

/// Extracts the computed body property from one top-level struct declaration.
struct ViewBodySourceEditor: Sendable {
    func rewriteMemberReferences(
        in expression: String,
        from body: ExtractedViewBody
    ) throws -> String {
        let withState = try rewriteStateReferences(
            in: expression,
            declarations: body.stateDeclarations
        )
        return try rewriteEnvironmentReferences(
            in: withState,
            declarations: body.environmentDeclarations
        )
    }

    func extract(in source: String, typeName: String) throws -> ExtractedViewBody {
        let syntaxTree = Parser.parse(source: source)
        guard !syntaxTree.hasError else {
            throw RuntimeViewLoweringError.malformedSyntax
        }

        let matchingTypes = syntaxTree.statements.compactMap { statement -> StructDeclSyntax? in
            guard let declaration = statement.item.as(DeclSyntax.self) else {
                return nil
            }
            return declaration.as(StructDeclSyntax.self)
        }.filter { $0.name.text == typeName }

        guard matchingTypes.count == 1, let typeDeclaration = matchingTypes.first else {
            let detail = matchingTypes.isEmpty
                ? "no top-level struct named \(typeName)"
                : "more than one top-level struct named \(typeName)"
            throw RuntimeViewLoweringError.unsupportedExpression(detail)
        }

        let bodyBindings = typeDeclaration.memberBlock.members
            .compactMap { $0.decl.as(VariableDeclSyntax.self) }
            .flatMap(\.bindings)
            .filter { binding in
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    return false
                }
                return identifier.identifier.text == "body"
            }

        guard bodyBindings.count == 1, let bodyBinding = bodyBindings.first else {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "struct \(typeName) must declare exactly one computed body property"
            )
        }

        let statements = try getterStatements(for: bodyBinding, typeName: typeName)
        guard !statements.isEmpty else {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "struct \(typeName) has an empty body getter"
            )
        }

        let expression: String
        if statements.count == 1, let statement = statements.first,
           let viewExpression = statement.item.as(ExprSyntax.self) {
            expression = viewExpression.trimmedDescription
        } else if statements.count == 1, let statement = statements.first,
                  let returnStatement = statement.item.as(ReturnStmtSyntax.self),
                  let returnedExpression = returnStatement.expression {
            expression = returnedExpression.trimmedDescription
        } else if statements.count == 1, let statement = statements.first,
                  viewBuilderConditional(in: statement.item) != nil {
            expression = "Group {\n\(statement.trimmedDescription)\n}"
        } else {
            guard statements.allSatisfy({
                $0.item.as(ExprSyntax.self) != nil || viewBuilderConditional(in: $0.item) != nil
            }) else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "struct \(typeName) body must contain view expressions"
                )
            }

            let children = statements.map(\.trimmedDescription).joined(separator: "\n")
            expression = "Group {\n\(children)\n}"
        }

        let stateDeclarations = try viewStateDeclarations(in: typeDeclaration, typeName: typeName)
        let environmentDeclarations = try viewEnvironmentDeclarations(in: typeDeclaration, typeName: typeName)
        let stateNames = Set(stateDeclarations.map(\.name))
        if let duplicateName = environmentDeclarations.map(\.name).first(where: { stateNames.contains($0) }) {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "view property \(duplicateName) has more than one supported property wrapper in \(typeName)"
            )
        }

        let stateRewrittenExpression = try rewriteStateReferences(
            in: expression,
            declarations: stateDeclarations
        )
        return ExtractedViewBody(
            expression: try rewriteEnvironmentReferences(
                in: stateRewrittenExpression,
                declarations: environmentDeclarations
            ),
            stateDeclarations: stateDeclarations,
            environmentDeclarations: environmentDeclarations
        )
    }

    private func viewEnvironmentDeclarations(
        in typeDeclaration: StructDeclSyntax,
        typeName: String
    ) throws -> [ViewEnvironmentDeclaration] {
        var declarations: [ViewEnvironmentDeclaration] = []
        var names = Set<String>()
        let variables = typeDeclaration.memberBlock.members.compactMap { member in
            member.decl.as(VariableDeclSyntax.self)
        }

        for variable in variables {
            let environmentAttributes = variable.attributes.compactMap { element -> AttributeSyntax? in
                guard case .attribute(let attribute) = element else { return nil }
                let name = attribute.attributeName.trimmedDescription
                return name == "Environment" || name.hasSuffix(".Environment") ? attribute : nil
            }
            guard !environmentAttributes.isEmpty else { continue }

            guard environmentAttributes.count == 1,
                  let key = supportedEnvironmentKey(environmentAttributes[0]) else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "only @Environment(\\.scenePhase) and @Environment(\\.dismiss) are supported in \(typeName) during Step 28.2"
                )
            }
            guard variable.bindingSpecifier.text == "var",
                  variable.bindings.count == 1,
                  let binding = variable.bindings.first,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  case nil = binding.initializer,
                  case nil = binding.accessorBlock else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "@Environment(\\.\(environmentKeyName(key))) in \(typeName) must be one stored mutable property"
                )
            }

            let name = identifier.identifier.text
            guard names.insert(name).inserted else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "environment property \(name) is declared more than once in \(typeName)"
                )
            }
            declarations.append(ViewEnvironmentDeclaration(
                name: name,
                storageName: environmentStorageName(for: key),
                key: key
            ))
        }
        return declarations
    }

    private func supportedEnvironmentKey(_ attribute: AttributeSyntax) -> ViewEnvironmentKey? {
        let source = String(attribute.trimmedDescription.filter { !$0.isWhitespace })
        switch source {
        case #"@Environment(\.scenePhase)"#, #"@SwiftUI.Environment(\.scenePhase)"#:
            return .scenePhase
        case #"@Environment(\.dismiss)"#, #"@SwiftUI.Environment(\.dismiss)"#:
            return .dismiss
        default:
            return nil
        }
    }

    private var scenePhaseStorageName: String {
        "__swiftpouch_environment_scenePhase"
    }

    private var dismissStorageName: String {
        "__swiftpouch_environment_dismiss"
    }

    private func environmentStorageName(for key: ViewEnvironmentKey) -> String {
        switch key {
        case .scenePhase:
            return scenePhaseStorageName
        case .dismiss:
            return dismissStorageName
        }
    }

    private func environmentKeyName(_ key: ViewEnvironmentKey) -> String {
        switch key {
        case .scenePhase:
            return "scenePhase"
        case .dismiss:
            return "dismiss"
        }
    }

    private func viewStateDeclarations(
        in typeDeclaration: StructDeclSyntax,
        typeName: String
    ) throws -> [ViewStateDeclaration] {
        var declarations: [ViewStateDeclaration] = []
        var names = Set<String>()
        let variables = typeDeclaration.memberBlock.members.compactMap { member in
            member.decl.as(VariableDeclSyntax.self)
        }

        for variable in variables where hasStateAttribute(variable) {
            guard variable.bindingSpecifier.text == "var" else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "State properties in \(typeName) must be mutable variables"
                )
            }

            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    throw RuntimeViewLoweringError.unsupportedExpression(
                        "State properties in \(typeName) must use simple names"
                    )
                }

                let name = identifier.identifier.text
                guard names.insert(name).inserted else {
                    throw RuntimeViewLoweringError.unsupportedExpression(
                        "State property \(name) is declared more than once in \(typeName)"
                    )
                }
                guard let initializer = binding.initializer?.value,
                      let source = staticStateInitializer(initializer) else {
                    throw RuntimeViewLoweringError.unsupportedExpression(
                        "State property \(name) must start with a plain String or Bool literal"
                    )
                }

                declarations.append(ViewStateDeclaration(
                    name: name,
                    storageName: stateStorageName(ownerTypeName: typeName, propertyName: name),
                    initializer: source
                ))
            }
        }
        return declarations
    }

    private func hasStateAttribute(_ variable: VariableDeclSyntax) -> Bool {
        return variable.attributes.contains { element in
            guard case .attribute(let attribute) = element else {
                return false
            }
            let name = attribute.attributeName.trimmedDescription
            return name == "State" || name.hasSuffix(".State")
        }
    }

    private func staticStateInitializer(_ expression: ExprSyntax) -> String? {
        if expression.as(BooleanLiteralExprSyntax.self) != nil {
            return expression.trimmedDescription
        }
        guard expression.as(StringLiteralExprSyntax.self) != nil else {
            return nil
        }
        let token = expression.trimmedDescription
        guard token.hasPrefix("\""), token.hasSuffix("\""),
              !token.hasPrefix("\"\"\""), !token.hasSuffix("\"\"\""),
              !token.dropFirst().dropLast().contains("\\") else {
            return nil
        }
        return token
    }

    private func rewriteStateReferences(
        in expression: String,
        declarations: [ViewStateDeclaration]
    ) throws -> String {
        guard !declarations.isEmpty else { return expression }

        let replacementsByName = Dictionary(uniqueKeysWithValues: declarations.map {
            ($0.name, $0.storageName)
        })
        return try rewriteViewPropertyReferences(
            in: expression,
            replacementsByName: replacementsByName,
            projectedReferencesAllowed: true,
            propertyWrapperName: "@State"
        )
    }

    private func rewriteEnvironmentReferences(
        in expression: String,
        declarations: [ViewEnvironmentDeclaration]
    ) throws -> String {
        guard !declarations.isEmpty else { return expression }

        let replacementsByName = Dictionary(uniqueKeysWithValues: declarations.map {
            ($0.name, $0.storageName)
        })
        let rewritten = try rewriteViewPropertyReferences(
            in: expression,
            replacementsByName: replacementsByName,
            projectedReferencesAllowed: false,
            propertyWrapperName: "@Environment",
            directCallNames: Set(declarations.filter { $0.key == .dismiss }.map(\.name))
        )
        return try qualifyScenePhaseCases(in: rewritten)
    }

    private func qualifyScenePhaseCases(in expression: String) throws -> String {
        let storage = NSRegularExpression.escapedPattern(for: scenePhaseStorageName)
        let cases = "active|inactive|background"
        let phaseOnRight = try NSRegularExpression(
            pattern: "(\(storage)\\s*(?:==|!=)\\s*)\\.(\(cases))\\b"
        )
        let phaseOnLeft = try NSRegularExpression(
            pattern: "\\.(\(cases))\\s*(==|!=)\\s*(\(storage))\\b"
        )

        let fullRange = NSRange(expression.startIndex..<expression.endIndex, in: expression)
        let rightQualified = phaseOnRight.stringByReplacingMatches(
            in: expression,
            range: fullRange,
            withTemplate: "$1__SwiftPouchScenePhase.$2"
        )
        let leftRange = NSRange(rightQualified.startIndex..<rightQualified.endIndex, in: rightQualified)
        return phaseOnLeft.stringByReplacingMatches(
            in: rightQualified,
            range: leftRange,
            withTemplate: "__SwiftPouchScenePhase.$1 $2 $3"
        )
    }

    private func rewriteViewPropertyReferences(
        in expression: String,
        replacementsByName: [String: String],
        projectedReferencesAllowed: Bool,
        propertyWrapperName: String,
        directCallNames: Set<String> = []
    ) throws -> String {
        let syntaxTree = Parser.parse(source: expression)
        guard !syntaxTree.hasError else {
            throw RuntimeViewLoweringError.malformedSyntax
        }

        let localBindings = StateLocalBindingVisitor()
        localBindings.walk(syntaxTree)
        if let shadowedName = localBindings.names.intersection(replacementsByName.keys).sorted().first {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "view body shadows \(propertyWrapperName) property \(shadowedName); rename the local binding"
            )
        }

        let visitor = StateReferenceVisitor(
            replacementsByName: replacementsByName,
            projectedReferencesAllowed: projectedReferencesAllowed,
            directCallNames: directCallNames
        )
        visitor.walk(syntaxTree)
        if let projectedName = visitor.unsupportedProjectedPropertyName {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "\(propertyWrapperName) property \(projectedName) does not support projected access"
            )
        }
        if let propertyName = visitor.unsupportedFunctionReferenceName {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "\(propertyWrapperName) property \(propertyName) must be invoked directly as a function"
            )
        }

        var bytes = Array(expression.utf8)
        for replacement in visitor.replacements.sorted(by: { $0.start > $1.start }) {
            guard replacement.start <= replacement.end, replacement.end <= bytes.count else {
                throw RuntimeViewLoweringError.malformedSyntax
            }
            bytes.replaceSubrange(replacement.start..<replacement.end, with: replacement.text.utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func stateStorageName(ownerTypeName: String, propertyName: String) -> String {
        func hex(_ value: String) -> String {
            let digits = Array("0123456789abcdef")
            return value.utf8.map { byte in
                String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
            }.joined()
        }
        return "__swiftpouch_state_\(hex(ownerTypeName))_\(hex(propertyName))"
    }

    func getterStatements(
        for binding: PatternBindingSyntax,
        typeName: String
    ) throws -> CodeBlockItemListSyntax {
        guard let accessorBlock = binding.accessorBlock else {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "struct \(typeName) body must be a computed property"
            )
        }

        switch accessorBlock.accessors {
        case .getter(let statements):
            return statements
        case .accessors(let accessors):
            let getters = accessors.filter { $0.accessorSpecifier.text == "get" }
            guard getters.count == 1, let getter = getters.first, let body = getter.body else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "struct \(typeName) body must have one synchronous getter"
                )
            }
            return body.statements
        }
    }
}

private struct StateReferenceReplacement {
    let start: Int
    let end: Int
    let text: String
}

private final class StateLocalBindingVisitor: SyntaxVisitor {
    private(set) var names = Set<String>()

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text)
        return .visitChildren
    }
}

private final class StateReferenceVisitor: SyntaxVisitor {
    private let replacementsByName: [String: String]
    private let projectedReferencesAllowed: Bool
    private let directCallNames: Set<String>
    private(set) var replacements: [StateReferenceReplacement] = []
    private(set) var unsupportedProjectedPropertyName: String?
    private(set) var unsupportedFunctionReferenceName: String?

    init(
        replacementsByName: [String: String],
        projectedReferencesAllowed: Bool,
        directCallNames: Set<String>
    ) {
        self.replacementsByName = replacementsByName
        self.projectedReferencesAllowed = projectedReferencesAllowed
        self.directCallNames = directCallNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let rawName = node.baseName.text
        let projectedPrefix: PrefixOperatorExprSyntax?
        if let prefix = node.parent?.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "$" {
            projectedPrefix = prefix
        } else {
            projectedPrefix = nil
        }
        let isProjection = rawName.hasPrefix("$") || projectedPrefix != nil
        let propertyName = propertyName(from: rawName)
        guard let replacement = replacementsByName[propertyName] else {
            return .visitChildren
        }
        let isDirectCall = isFunctionName(node)
        if isDirectCall && !directCallNames.contains(propertyName) {
            return .visitChildren
        }
        if !isDirectCall && directCallNames.contains(propertyName) {
            unsupportedFunctionReferenceName = propertyName
            return .visitChildren
        }
        if isProjection && !projectedReferencesAllowed {
            unsupportedProjectedPropertyName = propertyName
            return .visitChildren
        }
        let start = projectedPrefix?.positionAfterSkippingLeadingTrivia.utf8Offset
            ?? node.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = projectedPrefix?.endPositionBeforeTrailingTrivia.utf8Offset
            ?? node.endPositionBeforeTrailingTrivia.utf8Offset
        replacements.append(StateReferenceReplacement(
            start: start,
            end: end,
            text: isProjection ? "$\(replacement)" : replacement
        ))
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let base = node.base?.as(DeclReferenceExprSyntax.self),
              base.baseName.text == "self" else {
            return .visitChildren
        }
        let rawPropertyName = node.declName.baseName.text
        let propertyName = propertyName(from: rawPropertyName)
        guard let replacement = replacementsByName[propertyName] else {
            return .visitChildren
        }
        let isDirectCall = isFunctionName(node)
        if isDirectCall && !directCallNames.contains(propertyName) {
            return .visitChildren
        }
        if !isDirectCall && directCallNames.contains(propertyName) {
            unsupportedFunctionReferenceName = propertyName
            return .skipChildren
        }
        let isProjection = rawPropertyName.hasPrefix("$")
            || node.trimmedDescription.contains(".$")
        if isProjection && !projectedReferencesAllowed {
            unsupportedProjectedPropertyName = propertyName
            return .skipChildren
        }
        replacements.append(StateReferenceReplacement(
            start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
            end: node.endPositionBeforeTrailingTrivia.utf8Offset,
            text: isProjection ? "$\(replacement)" : replacement
        ))
        return .skipChildren
    }

    private func propertyName(from reference: String) -> String {
        reference.hasPrefix("$") ? String(reference.dropFirst()) : reference
    }

    private func isFunctionName(_ node: some SyntaxProtocol) -> Bool {
        guard let call = node.parent?.as(FunctionCallExprSyntax.self) else { return false }
        return call.calledExpression.positionAfterSkippingLeadingTrivia.utf8Offset
                == node.positionAfterSkippingLeadingTrivia.utf8Offset
            && call.calledExpression.endPositionBeforeTrailingTrivia.utf8Offset
                == node.endPositionBeforeTrailingTrivia.utf8Offset
    }
}
