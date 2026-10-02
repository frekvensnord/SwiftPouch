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

        for statement in parsed.sourceFile.statements {
            if let declaration = statement.item.as(DeclSyntax.self)?.as(ClassDeclSyntax.self) {
                classes[declaration.name.text] = declaration
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

        let visitor = CompatibilityExpressionVisitor(enumVariableTypes: enumVariableTypes)
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
    private(set) var edits: [(range: Range<Int>, replacement: String)] = []

    init(enumVariableTypes: [String: String]) {
        self.enumVariableTypes = enumVariableTypes
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        if node.trimmedDescription == "\\.self" {
            edits.append((range: node.positionAfterSkippingLeadingTrivia.utf8Offset
                ..< node.endPositionBeforeTrailingTrivia.utf8Offset, replacement: "{ $0 }"))
        }
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
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
}
