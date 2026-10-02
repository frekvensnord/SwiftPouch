import Foundation

/// Describes how an imported module is supplied to interpreted source.
public enum ModuleIntegration: String, Codable, Hashable, Sendable {
    /// The upstream interpreter already supplies this module.
    case interpreterBuiltIn

    /// The host still needs to provide a narrow bridge for this module.
    case hostBridgeRequired

    /// The module needs a runtime implementation such as the SwiftUI renderer.
    case customRuntimeRequired
}

public struct ModuleRegistration: Codable, Equatable, Sendable {
    public let name: String
    public let integration: ModuleIntegration
    public let summary: String

    public init(name: String, integration: ModuleIntegration, summary: String) {
        self.name = name
        self.integration = integration
        self.summary = summary
    }
}

public enum ModuleRegistryError: Error, LocalizedError, Equatable, Sendable {
    case emptyName
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "A module registration must have a name."
        case .duplicateName(let name):
            return "The module '\(name)' is already registered."
        }
    }
}

/// Host-side inventory of modules that source analysis can resolve.
///
/// Registrations describe integration readiness. They do not add symbols to
/// SwiftScript themselves; the corresponding host bridge or runtime is wired
/// in its implementation step.
public struct InterpreterModuleRegistry: Sendable {
    private var registrations: [String: ModuleRegistration]

    public init() {
        registrations = [:]
    }

    public mutating func register(_ registration: ModuleRegistration) throws {
        let normalizedName = registration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw ModuleRegistryError.emptyName }
        guard registrations[normalizedName] == nil else {
            throw ModuleRegistryError.duplicateName(normalizedName)
        }

        registrations[normalizedName] = ModuleRegistration(
            name: normalizedName,
            integration: registration.integration,
            summary: registration.summary
        )
    }

    public func registration(for moduleName: String) -> ModuleRegistration? {
        registrations[moduleName]
    }

    /// Initial support inventory for the real chat app's imports.
    public static var targetApp: InterpreterModuleRegistry {
        var registry = InterpreterModuleRegistry()
        let initialModules = [
            ModuleRegistration(
                name: "Foundation",
                integration: .interpreterBuiltIn,
                summary: "Foundation symbols provided by SwiftScript."
            ),
            ModuleRegistration(
                name: "SwiftUI",
                integration: .customRuntimeRequired,
                summary: "Selected expressions lower to view snapshots, but module symbols and the full app view runtime are not installed for whole-source evaluation."
            ),
            ModuleRegistration(
                name: "Security",
                integration: .hostBridgeRequired,
                summary: "Requires a scoped Keychain and authentication bridge."
            ),
            ModuleRegistration(
                name: "UIKit",
                integration: .hostBridgeRequired,
                summary: "Requires a small UIKit compatibility bridge."
            )
        ]

        for module in initialModules {
            // This private, literal list contains unique non-empty names.
            registry.registrations[module.name] = module
        }
        return registry
    }
}
