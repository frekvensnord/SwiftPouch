import Foundation
import SwiftParser
import SwiftSyntax

public enum SourceDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case information
    case warning
    case error
}

public enum SourceDiagnosticCode: String, Codable, Equatable, Sendable {
    case malformedSyntax
    case unregisteredModule
    case moduleHostBridgeRequired
    case moduleCustomRuntimeRequired
    case unsupportedPropertyWrapper
    case partiallySupportedPropertyWrapper
    case unsupportedResultBuilder
    case unsupportedMacro
    case hostManagedEntryPoint
}

public struct SourceLocation: Codable, Equatable, Sendable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct SourceDiagnostic: Codable, Equatable, Sendable {
    public let code: SourceDiagnosticCode
    public let severity: SourceDiagnosticSeverity
    public let message: String
    public let location: SourceLocation?

    public init(
        code: SourceDiagnosticCode,
        severity: SourceDiagnosticSeverity,
        message: String,
        location: SourceLocation?
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.location = location
    }
}

public enum SourceFeature: String, Codable, Hashable, Sendable {
    case propertyWrappers
    case resultBuilders
    case macros
    case appEntryPoint
}

public struct SourceAnalysis: Codable, Equatable, Sendable {
    public let importedModules: [String]
    public let detectedFeatures: [SourceFeature]
    public let diagnostics: [SourceDiagnostic]

    public init(
        importedModules: [String],
        detectedFeatures: [SourceFeature],
        diagnostics: [SourceDiagnostic]
    ) {
        self.importedModules = importedModules
        self.detectedFeatures = detectedFeatures
        self.diagnostics = diagnostics
    }

    /// Partial-support findings remain blocking until the evaluation path can
    /// actually invoke the corresponding specialized runtime path.
    public var isReadyForEvaluation: Bool {
        !diagnostics.contains {
            $0.severity == .error || $0.code == .partiallySupportedPropertyWrapper
        }
    }
}

/// Parses Swift source and checks its imports and known runtime requirements.
public struct SourceAnalyzer: Sendable {
    private let moduleRegistry: InterpreterModuleRegistry

    public init(moduleRegistry: InterpreterModuleRegistry = .targetApp) {
        self.moduleRegistry = moduleRegistry
    }

    public func analyze(_ source: String, fileName: String = "<memory>") -> SourceAnalysis {
        let syntaxTree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: syntaxTree)
        let visitor = RuntimeRequirementVisitor(converter: converter)
        visitor.walk(syntaxTree)

        var diagnostics: [SourceDiagnostic] = []
        for importedModule in visitor.imports {
            guard let registration = moduleRegistry.registration(for: importedModule.name) else {
                diagnostics.append(SourceDiagnostic(
                    code: .unregisteredModule,
                    severity: .error,
                    message: "Module '\(importedModule.name)' is not registered with this interpreter host.",
                    location: importedModule.location
                ))
                continue
            }

            switch registration.integration {
            case .interpreterBuiltIn:
                break
            case .hostBridgeRequired:
                diagnostics.append(SourceDiagnostic(
                    code: .moduleHostBridgeRequired,
                    severity: .error,
                    message: "Module '\(registration.name)' cannot be used until its host bridge is installed. \(registration.summary)",
                    location: importedModule.location
                ))
            case .customRuntimeRequired:
                diagnostics.append(SourceDiagnostic(
                    code: .moduleCustomRuntimeRequired,
                    severity: .error,
                    message: "Module '\(registration.name)' is unavailable for whole-source evaluation. \(registration.summary)",
                    location: importedModule.location
                ))
            }
        }

        for feature in visitor.features {
            let diagnostic: SourceDiagnostic
            switch feature.feature {
            case .propertyWrappers:
                if feature.support == .partial {
                    diagnostic = SourceDiagnostic(
                        code: .partiallySupportedPropertyWrapper,
                        severity: .warning,
                        message: "@State matches the current snapshot subset: a mutable property with a plain String or Bool literal default. Per-view storage and reactive updates are not implemented yet.",
                        location: feature.location
                    )
                } else {
                    let message = feature.attributeName == "State"
                        ? "@State only supports plain String or Bool literal defaults in the current snapshot subset; this declaration is outside that subset."
                        : "Property wrapper '@\(feature.attributeName)' requires a SwiftUI state bridge that is not implemented yet."
                    diagnostic = SourceDiagnostic(
                        code: .unsupportedPropertyWrapper,
                        severity: .error,
                        message: message,
                        location: feature.location
                    )
                }
            case .resultBuilders:
                diagnostic = SourceDiagnostic(
                    code: .unsupportedResultBuilder,
                    severity: .error,
                    message: "Explicit '@\(feature.attributeName)' declarations are not evaluated from full source yet; selected view-builder expressions are supported only by the expression lowerer.",
                    location: feature.location
                )
            case .macros:
                diagnostic = SourceDiagnostic(
                    code: .unsupportedMacro,
                    severity: .error,
                    message: "Macro expansion '\(feature.attributeName)' is not supported by this interpreter host.",
                    location: feature.location
                )
            case .appEntryPoint:
                diagnostic = SourceDiagnostic(
                    code: .hostManagedEntryPoint,
                    severity: .warning,
                    message: "The '@main' entry point is owned by the native host; the interpreted app starts from its root view.",
                    location: feature.location
                )
            }
            diagnostics.append(diagnostic)
        }

        if syntaxTree.hasError {
            diagnostics.append(SourceDiagnostic(
                code: .malformedSyntax,
                severity: .error,
                message: "The Swift parser found incomplete or malformed syntax.",
                location: nil
            ))
        }

        diagnostics.sort { left, right in
            guard let leftLocation = left.location else { return false }
            guard let rightLocation = right.location else { return true }
            if leftLocation.line != rightLocation.line {
                return leftLocation.line < rightLocation.line
            }
            return leftLocation.column < rightLocation.column
        }

        return SourceAnalysis(
            importedModules: visitor.imports.map(\.name),
            detectedFeatures: visitor.uniqueFeatures,
            diagnostics: diagnostics
        )
    }
}

private struct ImportOccurrence {
    let name: String
    let location: SourceLocation
}

private struct FeatureOccurrence {
    let feature: SourceFeature
    let attributeName: String
    let location: SourceLocation
    let support: FeatureSupportLevel
}

private enum FeatureSupportLevel: Equatable, Sendable {
    case unsupported
    case partial
}

private final class RuntimeRequirementVisitor: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private(set) var imports: [ImportOccurrence] = []
    private(set) var features: [FeatureOccurrence] = []
    private var seenImports: Set<String> = []

    private let wrapperNames: Set<String> = [
        "Binding", "Environment", "ObservedObject", "Published", "State", "StateObject"
    ]
    private let builderNames: Set<String> = ["ViewBuilder"]

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let pathComponents = node.path.map { $0.name.text }
        if let moduleName = pathComponents.first, seenImports.insert(moduleName).inserted {
            imports.append(ImportOccurrence(name: moduleName, location: location(of: node)))
        }
        return .visitChildren
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let fullName = node.attributeName.trimmedDescription
        let attributeName = fullName.split(separator: ".").last.map(String.init) ?? fullName

        if builderNames.contains(attributeName) {
            features.append(FeatureOccurrence(
                feature: .resultBuilders,
                attributeName: attributeName,
                location: location(of: node),
                support: .unsupported
            ))
        } else if attributeName == "main" {
            features.append(FeatureOccurrence(
                feature: .appEntryPoint,
                attributeName: attributeName,
                location: location(of: node),
                support: .unsupported
            ))
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let attributes = node.attributes else {
            return .visitChildren
        }

        for element in attributes {
            guard case .attribute(let attribute) = element else { continue }
            let fullName = attribute.attributeName.trimmedDescription
            let attributeName = fullName.split(separator: ".").last.map(String.init) ?? fullName
            guard wrapperNames.contains(attributeName) else { continue }

            let support: FeatureSupportLevel = attributeName == "State" && hasSupportedStateDefault(node)
                ? .partial
                : .unsupported
            features.append(FeatureOccurrence(
                feature: .propertyWrappers,
                attributeName: attributeName,
                location: location(of: attribute),
                support: support
            ))
        }

        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        features.append(FeatureOccurrence(
            feature: .macros,
            attributeName: node.macroName.text,
            location: location(of: node),
            support: .unsupported
        ))
        return .visitChildren
    }

    private func hasSupportedStateDefault(_ declaration: VariableDeclSyntax) -> Bool {
        guard declaration.bindingSpecifier.text == "var",
              !declaration.bindings.isEmpty else {
            return false
        }

        return declaration.bindings.allSatisfy { binding in
            guard binding.pattern.as(IdentifierPatternSyntax.self) != nil,
                  let initializer = binding.initializer?.value else {
                return false
            }
            return isPlainStringOrBooleanLiteral(initializer)
        }
    }

    private func isPlainStringOrBooleanLiteral(_ expression: ExprSyntax) -> Bool {
        if expression.as(BooleanLiteralExprSyntax.self) != nil {
            return true
        }
        guard expression.as(StringLiteralExprSyntax.self) != nil else {
            return false
        }

        let literal = expression.trimmedDescription
        return literal.hasPrefix("\"")
            && literal.hasSuffix("\"")
            && !literal.hasPrefix("\"\"\"")
            && !literal.hasSuffix("\"\"\"")
            && !literal.dropFirst().dropLast().contains("\\")
    }

    var uniqueFeatures: [SourceFeature] {
        var seen: Set<SourceFeature> = []
        return features.compactMap { seen.insert($0.feature).inserted ? $0.feature : nil }
    }

    private func location(of node: some SyntaxProtocol) -> SourceLocation {
        let position = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return SourceLocation(line: position.line, column: position.column)
    }
}

public struct SourcePreflightError: Error, LocalizedError, Sendable {
    public let analysis: SourceAnalysis

    public init(analysis: SourceAnalysis) {
        self.analysis = analysis
    }

    public var errorDescription: String? {
        analysis.diagnostics.first(where: {
            $0.severity == .error || $0.code == .partiallySupportedPropertyWrapper
        })?.message
            ?? "Source analysis did not pass."
    }
}
