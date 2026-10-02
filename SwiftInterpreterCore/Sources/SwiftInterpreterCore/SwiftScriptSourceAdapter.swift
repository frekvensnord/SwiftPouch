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

        for statement in parsed.sourceFile.statements {
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

        var bytes = Array(source.utf8)
        for edit in edits.reversed() {
            bytes.replaceSubrange(edit.range, with: edit.replacement.utf8)
        }
        return PreparedSource(
            source: String(decoding: bytes, as: UTF8.self),
            optionalVariableTypes: optionalTypes
        )
    }
}
