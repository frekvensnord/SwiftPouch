import SwiftParser
import SwiftSyntax

/// Expands simple top-level custom `View` calls before view-expression lowering.
/// Synthesized memberwise initializers support immutable inputs and direct
/// projections of parent `@State` cells into child `@Binding` properties.
/// Projected child bindings are preserved when they are forwarded again.
struct CustomViewSourceExpander: Sendable {
    private let bodySourceEditor = ViewBodySourceEditor()

    func expand(
        _ expression: String,
        from source: String,
        rootTypeName: String
    ) throws -> String {
        let syntaxTree = Parser.parse(source: source)
        guard !syntaxTree.hasError else {
            throw RuntimeViewLoweringError.malformedSyntax
        }

        var declarations: [String: [StructDeclSyntax]] = [:]
        for statement in syntaxTree.statements {
            guard let declaration = statement.item.as(DeclSyntax.self)?.as(StructDeclSyntax.self) else {
                continue
            }
            declarations[declaration.name.text, default: []].append(declaration)
        }

        return try expand(
            expression,
            source: source,
            declarations: declarations,
            expansionStack: [rootTypeName],
            depth: 0
        )
    }

    private func expand(
        _ expression: String,
        source: String,
        declarations: [String: [StructDeclSyntax]],
        expansionStack: [String],
        depth: Int
    ) throws -> String {
        guard depth <= 64 else {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "custom view expansion exceeded 64 levels"
            )
        }

        let syntaxTree = Parser.parse(source: expression)
        guard !syntaxTree.hasError else {
            throw RuntimeViewLoweringError.malformedSyntax
        }
        guard syntaxTree.statements.count == 1,
              let rootExpression = syntaxTree.statements.first?.item.as(ExprSyntax.self) else {
            throw RuntimeViewLoweringError.expectedSingleExpression
        }

        let visitor = CustomViewCallVisitor()
        visitor.walk(rootExpression)

        let candidates = visitor.calls.compactMap { call -> CustomViewCall? in
            guard let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) else {
                return nil
            }
            let name = reference.baseName.text
            guard declarations[name] != nil, !Self.builtInViewNames.contains(name) else {
                return nil
            }
            return CustomViewCall(
                name: name,
                syntax: call,
                start: call.positionAfterSkippingLeadingTrivia.utf8Offset,
                end: call.endPositionBeforeTrailingTrivia.utf8Offset
            )
        }

        guard !candidates.isEmpty else { return expression }

        // Expand outer custom calls first. Any nested custom calls passed as
        // arguments are discovered again after those arguments are substituted.
        let outermostCalls = candidates.filter { candidate in
            !candidates.contains { other in
                other.start < candidate.start && candidate.end <= other.end
            }
        }

        var rewritten = expression
        for customCall in outermostCalls.sorted(by: { $0.start > $1.start }) {
            guard customCall.start <= customCall.end,
                  customCall.end <= rewritten.utf8.count else {
                throw RuntimeViewLoweringError.malformedSyntax
            }

            guard !expansionStack.contains(customCall.name) else {
                let cycle = (expansionStack + [customCall.name]).joined(separator: " -> ")
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "recursive custom view composition is not supported: \(cycle)"
                )
            }

            guard let matchingDeclarations = declarations[customCall.name],
                  matchingDeclarations.count == 1,
                  let declaration = matchingDeclarations.first else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "custom view \(customCall.name) must have one top-level declaration"
                )
            }

            let definition = try customViewDefinition(
                named: customCall.name,
                declaration: declaration,
                source: source
            )
            let arguments = try argumentValues(for: customCall.syntax, definition: definition)
            let instantiatedBody = try substituting(arguments, into: definition.body)
            let expandedBody = try expand(
                instantiatedBody,
                source: source,
                declarations: declarations,
                expansionStack: expansionStack + [customCall.name],
                depth: depth + 1
            )

            var bytes = Array(rewritten.utf8)
            bytes.replaceSubrange(customCall.start..<customCall.end, with: expandedBody.utf8)
            rewritten = String(decoding: bytes, as: UTF8.self)
        }

        return try expand(
            rewritten,
            source: source,
            declarations: declarations,
            expansionStack: expansionStack,
            depth: depth + 1
        )
    }

    private func customViewDefinition(
        named name: String,
        declaration: StructDeclSyntax,
        source: String
    ) throws -> CustomViewDefinition {
        let conformsToView = declaration.inheritanceClause?.inheritedTypes.contains { inheritedType in
            let typeName = inheritedType.type.trimmedDescription
            return typeName == "View" || typeName.hasSuffix(".View")
        } ?? false
        guard conformsToView else {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "custom type \(name) must conform to View"
            )
        }

        let extractedBody = try bodySourceEditor.extract(in: source, typeName: name)
        guard extractedBody.stateDeclarations.isEmpty else {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "custom view \(name) cannot declare property-wrapped state in this step"
            )
        }

        var inputs: [CustomViewInput] = []
        for member in declaration.memberBlock.members {
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                let isBody = variable.bindings.contains { binding in
                    binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body"
                }
                if isBody {
                    guard variable.bindings.count == 1 else {
                        throw unsupportedCustomView(name, "body must be declared on its own")
                    }
                    continue
                }

                let wrapperNames = variable.attributes.compactMap { element -> String? in
                    guard case .attribute(let attribute) = element else { return nil }
                    return attribute.attributeName.trimmedDescription
                        .split(separator: ".")
                        .last
                        .map(String.init)
                }
                if wrapperNames.contains("Binding") {
                    let hasUnsupportedModifier = variable.modifiers.contains { modifier in
                        !["private", "fileprivate", "internal", "public"].contains(modifier.name.text)
                    }
                    guard wrapperNames == ["Binding"],
                          variable.bindingSpecifier.text == "var",
                          !hasUnsupportedModifier,
                          variable.bindings.count == 1,
                          let binding = variable.bindings.first,
                          let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                          case nil = binding.initializer,
                          case nil = binding.accessorBlock,
                          binding.typeAnnotation != nil else {
                        throw unsupportedCustomView(
                            name,
                            "@Binding inputs must be one mutable, typed stored property without a default"
                        )
                    }
                    inputs.append(CustomViewInput(
                        name: identifier.identifier.text,
                        kind: .binding
                    ))
                    continue
                }

                guard variable.bindingSpecifier.text == "let",
                      variable.attributes.isEmpty,
                      variable.modifiers.isEmpty,
                      variable.bindings.count == 1,
                      let binding = variable.bindings.first,
                      let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                      case nil = binding.initializer,
                      case nil = binding.accessorBlock,
                      let type = binding.typeAnnotation?.type,
                      case nil = type.as(FunctionTypeSyntax.self) else {
                    throw unsupportedCustomView(
                        name,
                        "stored inputs must be simple immutable let properties without wrappers or defaults"
                    )
                }
                inputs.append(CustomViewInput(name: identifier.identifier.text, kind: .value))
            } else {
                throw unsupportedCustomView(
                    name,
                    "only stored let inputs and the computed body property are supported"
                )
            }
        }

        return CustomViewDefinition(inputs: inputs, body: extractedBody.expression)
    }

    private func argumentValues(
        for call: FunctionCallExprSyntax,
        definition: CustomViewDefinition
    ) throws -> [String: CustomViewArgumentValue] {
        guard call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty,
              call.arguments.count == definition.inputs.count else {
            throw RuntimeViewLoweringError.unsupportedArgument(
                "custom view requires all declared inputs as labeled arguments"
            )
        }

        var values: [String: CustomViewArgumentValue] = [:]
        for (argument, input) in zip(call.arguments, definition.inputs) {
            guard argument.label?.text == input.name,
                  argument.expression.as(ClosureExprSyntax.self) == nil else {
                throw RuntimeViewLoweringError.unsupportedArgument(
                    "custom view input \(input.name) must be a labeled non-closure expression"
                )
            }
            let expression = argument.expression.trimmedDescription
            if input.kind == .binding {
                guard let projectedName = projectedBindingName(expression) else {
                    throw RuntimeViewLoweringError.unsupportedArgument(
                        "custom view @Binding input \(input.name) must receive a direct $state projection"
                    )
                }
                values[input.name] = CustomViewArgumentValue(
                    expression: projectedName,
                    supportsProjection: true
                )
            } else {
                values[input.name] = CustomViewArgumentValue(
                    expression: expression,
                    supportsProjection: false
                )
            }
        }
        return values
    }

    private func projectedBindingName(_ expression: String) -> String? {
        guard expression.first == "$" else { return nil }
        let identifier = String(expression.dropFirst())
        guard let first = identifier.first,
              first == "_" || first.isLetter,
              identifier.dropFirst().allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return identifier
    }

    private func substituting(
        _ values: [String: CustomViewArgumentValue],
        into body: String
    ) throws -> String {
        guard !values.isEmpty else { return body }

        let syntaxTree = Parser.parse(source: body)
        guard !syntaxTree.hasError,
              syntaxTree.statements.count == 1,
              let expression = syntaxTree.statements.first?.item.as(ExprSyntax.self) else {
            throw RuntimeViewLoweringError.malformedSyntax
        }

        let localBindings = IdentifierPatternNameVisitor()
        localBindings.walk(expression)
        if let shadowedName = localBindings.names.sorted().first(where: { values[$0] != nil }) {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "custom view body shadows input \(shadowedName); rename the local binding"
            )
        }

        let references = StoredPropertyReferenceVisitor()
        references.walk(expression)
        var replacements: [SourceReplacement] = []
        for reference in references.references {
            guard let value = values[reference.name], !reference.isFunctionName else { continue }
            if reference.isProjection && !value.supportsProjection {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "custom view input \(reference.name) is not a projected @Binding value"
                )
            }
            replacements.append(SourceReplacement(
                start: reference.start,
                end: reference.end,
                text: reference.isProjection ? "$\(value.expression)" : value.expression
            ))
        }
        replacements.sort { $0.start > $1.start }

        var bytes = Array(body.utf8)
        for replacement in replacements {
            guard replacement.start <= replacement.end, replacement.end <= bytes.count else {
                throw RuntimeViewLoweringError.malformedSyntax
            }
            bytes.replaceSubrange(replacement.start..<replacement.end, with: replacement.text.utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func unsupportedCustomView(_ name: String, _ reason: String) -> RuntimeViewLoweringError {
        .unsupportedExpression("custom view \(name): \(reason)")
    }

    private static let builtInViewNames: Set<String> = [
        "Text", "Image", "Color", "RoundedRectangle", "Rectangle", "Circle", "Capsule",
        "VStack", "HStack", "Group", "EmptyView", "Spacer", "Divider"
    ]
}

private struct CustomViewDefinition {
    let inputs: [CustomViewInput]
    let body: String
}

private struct CustomViewInput {
    let name: String
    let kind: Kind

    enum Kind: Equatable {
        case value
        case binding
    }
}

private struct CustomViewArgumentValue {
    let expression: String
    let supportsProjection: Bool
}

private struct CustomViewCall {
    let name: String
    let syntax: FunctionCallExprSyntax
    let start: Int
    let end: Int
}

private struct SourceReplacement {
    let start: Int
    let end: Int
    let text: String
}

private final class CustomViewCallVisitor: SyntaxVisitor {
    private(set) var calls: [FunctionCallExprSyntax] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if isInsideButtonActionClosure(node) {
            return .skipChildren
        }
        calls.append(node)
        return .visitChildren
    }
}

private struct StoredPropertyReference {
    let name: String
    let start: Int
    let end: Int
    let isFunctionName: Bool
    let isProjection: Bool
}

private final class StoredPropertyReferenceVisitor: SyntaxVisitor {
    private(set) var references: [StoredPropertyReference] = []

    init() {
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
        let start = projectedPrefix?.positionAfterSkippingLeadingTrivia.utf8Offset
            ?? node.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = projectedPrefix?.endPositionBeforeTrailingTrivia.utf8Offset
            ?? node.endPositionBeforeTrailingTrivia.utf8Offset
        var isFunctionName = false
        if let call = node.parent?.as(FunctionCallExprSyntax.self) {
            isFunctionName = call.calledExpression.positionAfterSkippingLeadingTrivia.utf8Offset
                    == node.positionAfterSkippingLeadingTrivia.utf8Offset
                && call.calledExpression.endPositionBeforeTrailingTrivia.utf8Offset
                    == node.endPositionBeforeTrailingTrivia.utf8Offset
        }

        references.append(
            StoredPropertyReference(
                name: propertyName(from: rawName),
                start: start,
                end: end,
                isFunctionName: isFunctionName,
                isProjection: rawName.hasPrefix("$") || projectedPrefix != nil
            )
        )
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let base = node.base?.as(DeclReferenceExprSyntax.self),
              base.baseName.text == "self" else {
            return .visitChildren
        }

        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = node.endPositionBeforeTrailingTrivia.utf8Offset
        let isFunctionName: Bool
        if let call = node.parent?.as(FunctionCallExprSyntax.self) {
            isFunctionName = call.calledExpression.positionAfterSkippingLeadingTrivia.utf8Offset == start
                && call.calledExpression.endPositionBeforeTrailingTrivia.utf8Offset == end
        } else {
            isFunctionName = false
        }

        let rawName = node.declName.baseName.text
        references.append(StoredPropertyReference(
            name: propertyName(from: rawName),
            start: start,
            end: end,
            isFunctionName: isFunctionName,
            isProjection: rawName.hasPrefix("$") || node.trimmedDescription.contains(".$")
        ))
        return .skipChildren
    }

    private func propertyName(from reference: String) -> String {
        reference.hasPrefix("$") ? String(reference.dropFirst()) : reference
    }
}

private final class IdentifierPatternNameVisitor: SyntaxVisitor {
    private(set) var names = Set<String>()

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text)
        return .visitChildren
    }
}
