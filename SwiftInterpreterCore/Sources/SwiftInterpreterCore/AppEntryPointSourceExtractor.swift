import Foundation
import SwiftParser
import SwiftSyntax

/// Identifies the interpreted app declaration and the view created by its
/// WindowGroup. The native host owns the actual app lifecycle.
public struct InterpretedAppEntryPoint: Equatable, Sendable {
    public let appTypeName: String
    public let rootViewTypeName: String

    public init(appTypeName: String, rootViewTypeName: String) {
        self.appTypeName = appTypeName
        self.rootViewTypeName = rootViewTypeName
    }
}

/// Failures produced while resolving the target's supported SwiftUI app entry.
public enum AppEntryPointExtractionError: Error, Equatable, LocalizedError, Sendable {
    case malformedSyntax
    case noMainApp
    case multipleMainApps
    case appMustConformToApp(String)
    case bodyPropertyCount(typeName: String, count: Int)
    case unsupportedAppBody(String)
    case unsupportedWindowGroup
    case unsupportedRootViewExpression
    case rootViewTypeNotFound(String)
    case multipleRootViewTypes(String)
    case rootViewMustConformToView(String)

    public var errorDescription: String? {
        switch self {
        case .malformedSyntax:
            return "The Swift parser found malformed app-entry syntax."
        case .noMainApp:
            return "No top-level struct marked with @main was found."
        case .multipleMainApps:
            return "More than one top-level struct is marked with @main."
        case .appMustConformToApp(let typeName):
            return "The @main struct \(typeName) must conform to App or SwiftUI.App."
        case .bodyPropertyCount(let typeName, let count):
            return "The @main struct \(typeName) must declare exactly one body property; found \(count)."
        case .unsupportedAppBody(let typeName):
            return "The body of \(typeName) must be one computed expression that creates WindowGroup."
        case .unsupportedWindowGroup:
            return "The supported app entry requires WindowGroup with one direct root-view initializer closure."
        case .unsupportedRootViewExpression:
            return "WindowGroup must directly create one no-argument top-level view struct."
        case .rootViewTypeNotFound(let typeName):
            return "The WindowGroup root type \(typeName) is not a top-level struct in this source."
        case .multipleRootViewTypes(let typeName):
            return "More than one top-level struct is named \(typeName)."
        case .rootViewMustConformToView(let typeName):
            return "The WindowGroup root struct \(typeName) must conform to View or SwiftUI.View."
        }
    }
}

/// Finds the single @main SwiftUI app and its direct WindowGroup root view.
///
/// This deliberately handles the app-entry shape used by SwiftChat. It only
/// discovers the root type; it does not execute the app declaration or build
/// a rendered view tree.
public struct AppEntryPointSourceExtractor: Sendable {
    public init() {}

    public func extract(from source: String) throws -> InterpretedAppEntryPoint {
        let syntaxTree = Parser.parse(source: source)
        guard !syntaxTree.hasError else {
            throw AppEntryPointExtractionError.malformedSyntax
        }

        let topLevelStructs = syntaxTree.statements.compactMap { statement -> StructDeclSyntax? in
            guard let declaration = statement.item.as(DeclSyntax.self) else {
                return nil
            }
            return declaration.as(StructDeclSyntax.self)
        }
        let mainApps = topLevelStructs.filter(hasMainAttribute)

        guard !mainApps.isEmpty else {
            throw AppEntryPointExtractionError.noMainApp
        }
        guard mainApps.count == 1, let appDeclaration = mainApps.first else {
            throw AppEntryPointExtractionError.multipleMainApps
        }

        let appTypeName = appDeclaration.name.text
        guard conforms(appDeclaration, to: "App") else {
            throw AppEntryPointExtractionError.appMustConformToApp(appTypeName)
        }

        let appBody = try bodyExpression(in: appDeclaration)
        guard let windowGroup = appBody.as(FunctionCallExprSyntax.self),
              isWindowGroup(windowGroup),
              windowGroup.arguments.isEmpty,
              windowGroup.additionalTrailingClosures.isEmpty,
              let rootClosure = windowGroup.trailingClosure,
              let rootExpression = singleExpression(in: rootClosure.statements) else {
            throw AppEntryPointExtractionError.unsupportedWindowGroup
        }

        guard let rootCall = rootExpression.as(FunctionCallExprSyntax.self),
              let rootTypeReference = rootCall.calledExpression.as(DeclReferenceExprSyntax.self),
              rootCall.arguments.isEmpty,
              rootCall.trailingClosure == nil,
              rootCall.additionalTrailingClosures.isEmpty else {
            throw AppEntryPointExtractionError.unsupportedRootViewExpression
        }

        let rootViewTypeName = rootTypeReference.baseName.text
        let matchingRootTypes = topLevelStructs.filter { $0.name.text == rootViewTypeName }
        guard !matchingRootTypes.isEmpty else {
            throw AppEntryPointExtractionError.rootViewTypeNotFound(rootViewTypeName)
        }
        guard matchingRootTypes.count == 1, let rootViewDeclaration = matchingRootTypes.first else {
            throw AppEntryPointExtractionError.multipleRootViewTypes(rootViewTypeName)
        }
        guard conforms(rootViewDeclaration, to: "View") else {
            throw AppEntryPointExtractionError.rootViewMustConformToView(rootViewTypeName)
        }

        return InterpretedAppEntryPoint(
            appTypeName: appTypeName,
            rootViewTypeName: rootViewTypeName
        )
    }

    private func hasMainAttribute(_ declaration: StructDeclSyntax) -> Bool {
        return declaration.attributes.contains { element in
            guard case .attribute(let attribute) = element else {
                return false
            }
            let fullName = attribute.attributeName.trimmedDescription
            return fullName.split(separator: ".").last.map(String.init) == "main"
        }
    }

    private func conforms(_ declaration: StructDeclSyntax, to protocolName: String) -> Bool {
        guard let inheritedTypes = declaration.inheritanceClause?.inheritedTypes else {
            return false
        }
        return inheritedTypes.contains { inheritedType in
            let name = inheritedType.type.trimmedDescription
            return name == protocolName || name == "SwiftUI.\(protocolName)"
        }
    }

    private func bodyExpression(in appDeclaration: StructDeclSyntax) throws -> ExprSyntax {
        let bodyBindings = appDeclaration.memberBlock.members
            .compactMap { $0.decl.as(VariableDeclSyntax.self) }
            .flatMap(\.bindings)
            .filter { binding in
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    return false
                }
                return identifier.identifier.text == "body"
            }

        guard bodyBindings.count == 1, let bodyBinding = bodyBindings.first else {
            throw AppEntryPointExtractionError.bodyPropertyCount(
                typeName: appDeclaration.name.text,
                count: bodyBindings.count
            )
        }
        guard let accessorBlock = bodyBinding.accessorBlock else {
            throw AppEntryPointExtractionError.unsupportedAppBody(appDeclaration.name.text)
        }

        let statements: CodeBlockItemListSyntax
        switch accessorBlock.accessors {
        case .getter(let getterStatements):
            statements = getterStatements
        case .accessors(let accessors):
            guard accessors.count == 1,
                  let getter = accessors.first,
                  getter.accessorSpecifier.text == "get",
                  let body = getter.body else {
                throw AppEntryPointExtractionError.unsupportedAppBody(appDeclaration.name.text)
            }
            statements = body.statements
        }

        guard let expression = singleExpression(in: statements) else {
            throw AppEntryPointExtractionError.unsupportedAppBody(appDeclaration.name.text)
        }
        return expression
    }

    private func singleExpression(in statements: CodeBlockItemListSyntax) -> ExprSyntax? {
        guard statements.count == 1, let statement = statements.first else {
            return nil
        }
        if let expression = statement.item.as(ExprSyntax.self) {
            return expression
        }
        if let returnStatement = statement.item.as(ReturnStmtSyntax.self) {
            return returnStatement.expression
        }
        return nil
    }

    private func isWindowGroup(_ call: FunctionCallExprSyntax) -> Bool {
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text == "WindowGroup"
        }
        guard let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self) else {
            return false
        }
        return memberAccess.base?.trimmedDescription == "SwiftUI"
            && memberAccess.declName.baseName.text == "WindowGroup"
    }
}
