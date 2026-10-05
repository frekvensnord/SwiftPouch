import SwiftScriptAST
import SwiftSyntax

/// Retains declared optional types across ordinary kernel evaluations.
/// SwiftScript currently drops optional promotion on later assignments, so
/// the source adapter lets its own typed declaration path coerce the new value.
struct SwiftScriptSourceAdapter: Sendable {
    struct PreparedSource: Sendable {
        let source: String
        let optionalVariableTypes: [String: String]
    }

    func prepare(
        _ source: String,
        optionalVariableTypes previousTypes: [String: String]
    ) -> PreparedSource {
        let parsed = ScriptParser.parse(source)
        guard !parsed.hasErrors else {
            return PreparedSource(source: source, optionalVariableTypes: previousTypes)
        }

        var optionalTypes = previousTypes
        var edits: [(range: Range<Int>, replacement: String)] = []
        var classes: [String: ClassDeclSyntax] = [:]
        var enumVariableTypes: [String: String] = [:]
        var classEnumProperties: [String: [String: String]] = [:]
        var enumCaseOwners: [String: String] = [:]
        var ambiguousEnumCases: Set<String> = []

        for statement in parsed.sourceFile.statements {
            if let declaration = statement.item.as(DeclSyntax.self)?.as(ClassDeclSyntax.self) {
                classes[declaration.name.text] = declaration
                for member in declaration.memberBlock.members {
                    guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
                    for binding in variable.bindings {
                        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                              let type = binding.typeAnnotation?.type.as(IdentifierTypeSyntax.self) else { continue }
                        classEnumProperties[declaration.name.text, default: [:]][name] = type.name.text
                    }
                }
            }
            if let declaration = statement.item.as(DeclSyntax.self)?.as(EnumDeclSyntax.self) {
                for member in declaration.memberBlock.members {
                    guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                    for element in cases.elements {
                        let caseName = element.name.text
                        if enumCaseOwners[caseName] != nil { ambiguousEnumCases.insert(caseName) }
                        enumCaseOwners[caseName] = declaration.name.text
                    }
                }
            }
            if let declaration = statement.item.as(DeclSyntax.self)?.as(VariableDeclSyntax.self) {
                for binding in declaration.bindings {
                    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                    if let type = binding.typeAnnotation?.type.as(IdentifierTypeSyntax.self) {
                        enumVariableTypes[name] = type.name.text
                    } else if let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
                              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                              let base = member.base?.as(DeclReferenceExprSyntax.self) {
                        enumVariableTypes[name] = base.baseName.text
                    }
                }
            }
        }

        var classMembers: [String: [String]] = [:]
        var classProtocols: [String: [String]] = [:]

        for statement in parsed.sourceFile.statements {
            if let extensionDecl = statement.item.as(DeclSyntax.self)?.as(ExtensionDeclSyntax.self),
               let typeName = extensionDecl.extendedType.as(IdentifierTypeSyntax.self)?.name.text,
               classes[typeName] != nil {
                classMembers[typeName, default: []].append(contentsOf:
                    extensionDecl.memberBlock.members.map { $0.decl.trimmedDescription }
                )
                classProtocols[typeName, default: []].append(contentsOf:
                    extensionDecl.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
                )
                edits.append((
                    range: extensionDecl.positionAfterSkippingLeadingTrivia.utf8Offset
                        ..< extensionDecl.endPositionBeforeTrailingTrivia.utf8Offset,
                    replacement: ""
                ))
                continue
            }
            if let declaration = statement.item.as(DeclSyntax.self)?.as(VariableDeclSyntax.self) {
                for binding in declaration.bindings {
                    guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                    let name = identifier.identifier.text
                    if let annotatedType = binding.typeAnnotation?.type,
                       annotatedType.as(OptionalTypeSyntax.self) != nil {
                        optionalTypes[name] = annotatedType.trimmedDescription
                    } else {
                        optionalTypes.removeValue(forKey: name)
                    }
                }
                continue
            }

            guard let expression = statement.item.as(ExprSyntax.self),
                  let assignment = expression.as(InfixOperatorExprSyntax.self),
                  assignment.operator.is(AssignmentExprSyntax.self),
                  let target = assignment.leftOperand.as(DeclReferenceExprSyntax.self),
                  let optionalType = optionalTypes[target.baseName.text] else {
                continue
            }

            let rightSide = assignment.rightOperand
            let temporaryName = "__swiftpouchOptionalAssignment\(edits.count)"
            let replacement = "({ let \(temporaryName): \(optionalType) = \(rightSide.trimmedDescription); \(temporaryName) })()"
            edits.append((
                range: (
                    rightSide.positionAfterSkippingLeadingTrivia.utf8Offset
                        ..< rightSide.endPositionBeforeTrailingTrivia.utf8Offset
                ),
                replacement: replacement
            ))
        }

        for (typeName, declaration) in classes {
            if let members = classMembers[typeName], !members.isEmpty {
                let insertion = declaration.memberBlock.rightBrace.position.utf8Offset
                edits.append((range: insertion..<insertion, replacement: "\n" + members.joined(separator: "\n") + "\n"))
            }
            if let protocols = classProtocols[typeName], !protocols.isEmpty {
                let inheritance = declaration.inheritanceClause
                let insertion = inheritance?.inheritedTypes.last?.endPositionBeforeTrailingTrivia.utf8Offset
                    ?? declaration.name.endPositionBeforeTrailingTrivia.utf8Offset
                edits.append((range: insertion..<insertion,
                              replacement: (inheritance == nil ? ": " : ", ") + protocols.joined(separator: ", ")))
            }
        }

        for name in ambiguousEnumCases { enumCaseOwners.removeValue(forKey: name) }
        let visitor = CompatibilityExpressionVisitor(
            enumVariableTypes: enumVariableTypes,
            enumCaseOwners: enumCaseOwners,
            classEnumProperties: classEnumProperties
        )
        visitor.walk(parsed.sourceFile)
        edits.append(contentsOf: visitor.edits)

        var bytes = Array(source.utf8)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(edit.range, with: edit.replacement.utf8)
        }
        var adapted = String(decoding: bytes, as: UTF8.self)
        if source.contains("Result<"), !source.contains("enum Result") {
            adapted = "enum Result<Success, Failure> { case success(Success)\ncase failure(Failure) }\n" + adapted
        }
        return PreparedSource(
            source: adapted,
            optionalVariableTypes: optionalTypes
        )
    }
}

private final class CompatibilityExpressionVisitor: SyntaxVisitor {
    let enumVariableTypes: [String: String]
    let enumCaseOwners: [String: String]
    let classEnumProperties: [String: [String: String]]
    private(set) var edits: [(range: Range<Int>, replacement: String)] = []

    init(
        enumVariableTypes: [String: String],
        enumCaseOwners: [String: String],
        classEnumProperties: [String: [String: String]]
    ) {
        self.enumVariableTypes = enumVariableTypes
        self.enumCaseOwners = enumCaseOwners
        self.classEnumProperties = classEnumProperties
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == "urlSession" else { return .visitChildren }
        var ancestor = node.parent
        var insideClass = false
        while let current = ancestor {
            if current.is(ClassDeclSyntax.self) { insideClass = true; break }
            ancestor = current.parent
        }
        guard insideClass else { return .visitChildren }
        let labels = node.signature.parameterClause.parameters.map { $0.firstName.text }
        let suffix: String
        switch labels {
        case ["_", "dataTask", "didReceive", "completionHandler"]: suffix = "response"
        case ["_", "dataTask", "didReceive"]: suffix = "data"
        case ["_", "task", "didCompleteWithError"]: suffix = "complete"
        case ["_", "didBecomeInvalidWithError"]: suffix = "invalid"
        default: return .visitChildren
        }
        edits.append((range: node.name.positionAfterSkippingLeadingTrivia.utf8Offset
            ..< node.name.endPositionBeforeTrailingTrivia.utf8Offset,
            replacement: "__swiftpouch_urlSession_\(suffix)"))
        return .visitChildren
    }

    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        if node.trimmedDescription == "\\.self" {
            edits.append((range: node.positionAfterSkippingLeadingTrivia.utf8Offset
                ..< node.endPositionBeforeTrailingTrivia.utf8Offset, replacement: "{ $0 }"))
        }
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if node.operator.is(AssignmentExprSyntax.self) {
            let propertyName = node.leftOperand.as(DeclReferenceExprSyntax.self)?.baseName.text
                ?? node.leftOperand.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            let implicitCase = node.rightOperand.as(FunctionCallExprSyntax.self)?
                .calledExpression.as(MemberAccessExprSyntax.self)
                ?? node.rightOperand.as(MemberAccessExprSyntax.self)
            if let propertyName, let implicitCase, implicitCase.base == nil {
                var ancestor = node.parent
                while let current = ancestor {
                    if let type = current.as(ClassDeclSyntax.self) {
                        if let enumName = classEnumProperties[type.name.text]?[propertyName] {
                            let insertion = implicitCase.positionAfterSkippingLeadingTrivia.utf8Offset
                            edits.append((range: insertion..<insertion, replacement: enumName))
                        }
                        break
                    }
                    ancestor = current.parent
                }
            }
        }
        guard node.operator.trimmedDescription == "==",
              let variable = node.leftOperand.as(DeclReferenceExprSyntax.self),
              let enumType = enumVariableTypes[variable.baseName.text],
              let call = node.rightOperand.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.base == nil else { return .visitChildren }

        let insertion = member.positionAfterSkippingLeadingTrivia.utf8Offset
        edits.append((range: insertion..<insertion, replacement: enumType))
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        guard let expression = node.initializer?.value,
              expression.trimmedDescription.contains("??"),
              expression.trimmedDescription.contains("as? String") else { return .visitChildren }

        // SwiftScript's nil-coalescing operator currently unwraps a present
        // left side even when the right side is Optional. Restore the
        // Optional required by `guard let` using the source's cast type.
        edits.append((
            range: expression.positionAfterSkippingLeadingTrivia.utf8Offset
                ..< expression.endPositionBeforeTrailingTrivia.utf8Offset,
            replacement: "(\(expression.trimmedDescription)) as? String"
        ))
        return .skipChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let caseName = node.declName.baseName.text
        if node.base == nil {
            let owner: String?
            switch caseName {
            case "now" where node.parent?.as(FunctionCallExprSyntax.self) != nil:
                owner = "DispatchTime"
            case "ephemeral", "default":
                owner = "URLSessionConfiguration"
            case "allow":
                owner = "URLSession.ResponseDisposition"
            default:
                owner = nil
            }
            if let owner {
                edits.append((range: node.positionAfterSkippingLeadingTrivia.utf8Offset
                    ..< node.positionAfterSkippingLeadingTrivia.utf8Offset, replacement: owner))
                return .visitChildren
            }
        }
        guard node.base == nil, let owner = enumCaseOwners[caseName] else { return .visitChildren }
        var ancestor = node.parent
        while let current = ancestor {
            if let call = current.as(FunctionCallExprSyntax.self),
               call.calledExpression.trimmedDescription == ".failure" {
                let insertion = node.positionAfterSkippingLeadingTrivia.utf8Offset
                edits.append((range: insertion..<insertion, replacement: owner))
                break
            }
            if current.is(CodeBlockItemSyntax.self) { break }
            ancestor = current.parent
        }
        return .visitChildren
    }
}
