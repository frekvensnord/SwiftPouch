import SwiftParser
import SwiftSyntax

struct ViewStateDeclaration: Sendable {
    let name: String
    let initializer: String
}

struct ExtractedViewBody: Sendable {
    let expression: String
    let stateDeclarations: [ViewStateDeclaration]
}

/// Extracts the computed body property from one top-level struct declaration.
struct ViewBodySourceEditor: Sendable {
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
        } else {
            guard statements.allSatisfy({ $0.item.as(ExprSyntax.self) != nil }) else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "struct \(typeName) body must contain view expressions"
                )
            }

            let children = statements.map(\.trimmedDescription).joined(separator: "\n")
            expression = "Group {\n\(children)\n}"
        }

        return ExtractedViewBody(
            expression: expression,
            stateDeclarations: try viewStateDeclarations(in: typeDeclaration, typeName: typeName)
        )
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

                declarations.append(ViewStateDeclaration(name: name, initializer: source))
            }
        }
        return declarations
    }

    private func hasStateAttribute(_ variable: VariableDeclSyntax) -> Bool {
        guard let attributes = variable.attributes else {
            return false
        }
        return attributes.contains { element in
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

    private func getterStatements(
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
