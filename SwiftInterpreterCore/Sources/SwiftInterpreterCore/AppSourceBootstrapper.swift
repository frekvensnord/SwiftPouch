import SwiftParser
import SwiftSyntax

/// Selects executable model declarations and initializes the root view's owned
/// objects. SwiftUI view and App declarations remain source for the view lowerer.
struct AppSourceBootstrapper: Sendable {
    private let bodyEditor = ViewBodySourceEditor()

    func prepare(_ source: String, rootTypeName: String) throws -> String {
        let tree = Parser.parse(source: source)
        guard !tree.hasError else { throw RuntimeViewLoweringError.malformedSyntax }
        let root = try bodyEditor.extract(in: source, typeName: rootTypeName)
        var declarations: [String] = []
        for statement in tree.statements {
            guard let declaration = statement.item.as(DeclSyntax.self) else { continue }
            if let imported = declaration.as(ImportDeclSyntax.self) {
                let name = imported.path.trimmedDescription
                if name == "Foundation" || name == "Security" {
                    declarations.append(imported.trimmedDescription)
                }
            } else if let type = declaration.as(StructDeclSyntax.self) {
                if !isViewOrApp(type.inheritanceClause) {
                    declarations.append(type.trimmedDescription)
                }
            } else if let type = declaration.as(ClassDeclSyntax.self) {
                declarations.append(try observableClassSource(type))
            } else if let type = declaration.as(EnumDeclSyntax.self) {
                declarations.append(type.trimmedDescription)
            } else if let type = declaration.as(ProtocolDeclSyntax.self) {
                declarations.append(type.trimmedDescription)
            } else if let type = declaration.as(ExtensionDeclSyntax.self) {
                declarations.append(type.trimmedDescription)
            } else if let function = declaration.as(FunctionDeclSyntax.self) {
                declarations.append(function.trimmedDescription)
            } else if let variable = declaration.as(VariableDeclSyntax.self),
                      variable.attributes.isEmpty {
                declarations.append(variable.trimmedDescription)
            }
        }
        let objects = try objectInitializers(in: source, typeName: rootTypeName,
                                             declarations: root.objectDeclarations)
        return (declarations + objects).joined(separator: "\n\n")
    }

    private func isViewOrApp(_ inheritance: InheritanceClauseSyntax?) -> Bool {
        inheritance?.inheritedTypes.contains { item in
            ["View", "App", "SwiftUI.View", "SwiftUI.App"].contains(item.type.trimmedDescription)
        } ?? false
    }

    private func observableClassSource(_ declaration: ClassDeclSyntax) throws -> String {
        let offset = declaration.positionAfterSkippingLeadingTrivia.utf8Offset
        var bytes = Array(declaration.trimmedDescription.utf8)
        var edits: [(Range<Int>, String)] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            let published = variable.attributes.compactMap { element -> AttributeSyntax? in
                guard case .attribute(let attribute) = element,
                      attribute.attributeName.trimmedDescription.split(separator: ".").last == "Published"
                else { return nil }
                return attribute
            }
            guard !published.isEmpty else { continue }
            guard published.count == 1, variable.bindings.count == 1,
                  let binding = variable.bindings.first,
                  binding.pattern.as(IdentifierPatternSyntax.self) != nil,
                  binding.accessorBlock == nil, variable.bindingSpecifier.text == "var" else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "@Published in \(declaration.name.text) needs one stored mutable property"
                )
            }
            let insertion = binding.endPositionBeforeTrailingTrivia.utf8Offset - offset
            edits.append((insertion..<insertion, " { didSet { __swiftpouch_publishedChange() } }"))
            if let initializer = binding.initializer?.value,
               let member = initializer.as(MemberAccessExprSyntax.self),
               member.base == nil,
               let type = binding.typeAnnotation?.type.as(IdentifierTypeSyntax.self) {
                edits.append((
                    initializer.positionAfterSkippingLeadingTrivia.utf8Offset - offset
                        ..< initializer.endPositionBeforeTrailingTrivia.utf8Offset - offset,
                    "\(type.name.text).\(member.declName.baseName.text)"
                ))
            }
            for attribute in published {
                edits.append((attribute.positionAfterSkippingLeadingTrivia.utf8Offset - offset
                    ..< attribute.endPositionBeforeTrailingTrivia.utf8Offset - offset, ""))
            }
        }
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
                throw RuntimeViewLoweringError.malformedSyntax
            }
            bytes.replaceSubrange(range, with: replacement.utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func objectInitializers(
        in source: String,
        typeName: String,
        declarations: [ViewObjectDeclaration]
    ) throws -> [String] {
        guard !declarations.isEmpty else { return [] }
        let tree = Parser.parse(source: source)
        guard let type = tree.statements.compactMap({
            $0.item.as(DeclSyntax.self)?.as(StructDeclSyntax.self)
        }).first(where: { $0.name.text == typeName }) else {
            throw RuntimeViewLoweringError.malformedSyntax
        }
        let initializers = type.memberBlock.members.compactMap { $0.decl.as(InitializerDeclSyntax.self) }
            .filter { $0.signature.parameterClause.parameters.isEmpty }
        guard initializers.count <= 1 else {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "root view \(typeName) has multiple zero-argument initializers"
            )
        }
        var statements: [String] = []
        var initialized = Set<String>()
        if let initializer = initializers.first {
            guard let body = initializer.body else {
                throw RuntimeViewLoweringError.unsupportedExpression("root view initializer has no body")
            }
            for statement in body.statements {
                if let variable = statement.item.as(DeclSyntax.self)?.as(VariableDeclSyntax.self),
                   variable.bindingSpecifier.text == "let", variable.attributes.isEmpty,
                   variable.bindings.count == 1,
                   let binding = variable.bindings.first,
                   binding.pattern.as(IdentifierPatternSyntax.self) != nil,
                   binding.initializer != nil {
                    statements.append(variable.trimmedDescription)
                    continue
                }
                guard let expression = statement.item.as(ExprSyntax.self),
                      let (target, call) = stateObjectAssignment(expression),
                      target.baseName.text.hasPrefix("_"),
                      let object = declarations.first(where: {
                          "_" + $0.name == target.baseName.text && $0.isOwned
                      }),
                      call.calledExpression.trimmedDescription.split(separator: ".").last == "StateObject",
                      let wrapped = call.arguments.first(where: { $0.label?.text == "wrappedValue" }),
                      initialized.insert(object.name).inserted else {
                    throw RuntimeViewLoweringError.unsupportedExpression(
                        "root view \(typeName) initializer needs local lets and StateObject(wrappedValue:) assignments"
                    )
                }
                statements.append("let \(object.storageName) = \(wrapped.expression.trimmedDescription)")
            }
        }
        for object in declarations where !initialized.contains(object.name) {
            guard object.isOwned, let expression = object.initializer else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "root view object \(object.name) needs a StateObject initializer"
                )
            }
            statements.append("let \(object.storageName) = \(expression)")
        }
        return statements
    }

    private func stateObjectAssignment(
        _ expression: ExprSyntax
    ) -> (DeclReferenceExprSyntax, FunctionCallExprSyntax)? {
        if let assignment = expression.as(InfixOperatorExprSyntax.self),
           assignment.operator.is(AssignmentExprSyntax.self),
           let target = assignment.leftOperand.as(DeclReferenceExprSyntax.self),
           let call = assignment.rightOperand.as(FunctionCallExprSyntax.self) {
            return (target, call)
        }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            if elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
               let target = elements[0].as(DeclReferenceExprSyntax.self),
               let call = elements[2].as(FunctionCallExprSyntax.self) {
                return (target, call)
            }
        }
        return nil
    }
}
