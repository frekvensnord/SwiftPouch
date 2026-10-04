import Foundation
import Security
import XCTest
@testable import SwiftInterpreterCore

private final class MemoryKeychainBackend: ProjectKeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    private func key(_ service: String, _ account: String) -> String { service + "\u{0}" + account }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = items[key(service, account)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let item = key(service, account)
        guard items[item] == nil else { return errSecDuplicateItem }
        items[item] = data
        return errSecSuccess
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let item = key(service, account)
        guard items[item] != nil else { return errSecItemNotFound }
        items[item] = data
        return errSecSuccess
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        return items.removeValue(forKey: key(service, account)) == nil ? errSecItemNotFound : errSecSuccess
    }
}

final class ProjectKeychainBridgeTests: XCTestCase {
    private let declarations = #"""
    import Foundation
    import Security
    struct Credentials: Codable { var token: String }
    final class KeychainCredentialStore {
        private let service = "SwiftChat.codex-session"
        private let account = "oauth"

        func readCredentials() throws -> Credentials? {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            query.removeValue(forKey: kSecReturnData as String)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return try JSONDecoder().decode(Credentials.self, from: data)
        }

        func saveCredentials(_ credentials: Credentials) throws {
            let data = try JSONEncoder().encode(credentials)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                update.forEach { add[$0.key] = $0.value }
                let addStatus = SecItemAdd(add as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
                }
            } else if status != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }

        func deleteCredentials() throws {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
    }
    """#

    func testTargetCredentialOperationsPersistAcrossResetAndReopenAndRemainProjectScoped() async throws {
        let backend = MemoryKeychainBackend()
        let store = ProjectWorkspaceStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPouchKeychainTests-\(UUID())"))
        let id = ProjectID()
        let workspace = try store.workspace(for: id)
        let first = InterpreterKernel(workspace: workspace, keychainBackend: backend)
        let saved = try await first.evaluate(declarations + "\n" + #"""
        let credentials = KeychainCredentialStore()
        let initiallyEmpty = try credentials.readCredentials() == nil
        try credentials.saveCredentials(Credentials(token: "first"))
        let firstRead = try credentials.readCredentials()!.token
        try credentials.saveCredentials(Credentials(token: "updated"))
        let secondRead = try credentials.readCredentials()!.token
        "\(initiallyEmpty)|\(firstRead)|\(secondRead)"
        """#)
        XCTAssertEqual(saved.value, "true|first|updated")

        await first.reset()
        let afterReset = try await first.evaluate(declarations + "\n" + #"""
        let credentials = KeychainCredentialStore()
        try credentials.readCredentials()!.token
        """#)
        XCTAssertEqual(afterReset.value, "updated")

        let reopened = InterpreterKernel(workspace: try store.workspace(for: id), keychainBackend: backend)
        let afterReopen = try await reopened.evaluate(declarations + "\n" + #"""
        let credentials = KeychainCredentialStore()
        try credentials.readCredentials()!.token
        """#)
        XCTAssertEqual(afterReopen.value, "updated")

        let other = InterpreterKernel(workspace: try store.workspace(for: ProjectID()), keychainBackend: backend)
        let isolated = try await other.evaluate(declarations + "\n" + #"""
        let credentials = KeychainCredentialStore()
        try credentials.readCredentials() == nil
        """#)
        XCTAssertEqual(isolated.value, "true")

        let removed = try await reopened.evaluate(#"""
        try credentials.deleteCredentials()
        try credentials.readCredentials() == nil
        """#)
        XCTAssertEqual(removed.value, "true")
    }

    func testRejectsUnsupportedKeychainAttributesWithoutReachingBackend() async throws {
        let backend = MemoryKeychainBackend()
        let workspace = try ProjectWorkspaceStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPouchKeychainTests-\(UUID())")).workspace(for: ProjectID())
        let kernel = InterpreterKernel(workspace: workspace, keychainBackend: backend)
        let result = try await kernel.evaluate(#"""
        import Security
        let unrestricted: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "external", kSecAttrAccount as String: "oauth",
            "accessGroup": "another-app"]
        let invalid = SecItemDelete(unrestricted as CFDictionary)
        invalid == errSecParam
        """#)
        XCTAssertEqual(result.value, "true")
    }
}
