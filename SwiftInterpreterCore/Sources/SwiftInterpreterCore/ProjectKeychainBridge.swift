import Foundation
import Security
import SwiftScriptInterpreter

/// The host owns Keychain access. Only generic passwords in this project's
/// namespaced service can reach the system API.
protocol ProjectKeychainBackend: Sendable {
    func copy(service: String, account: String) -> (OSStatus, Data?)
    func add(service: String, account: String, data: Data) -> OSStatus
    func update(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

struct SystemProjectKeychainBackend: ProjectKeychainBackend {
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        var attributes = query(service, account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var attributes = query(service, account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemUpdate(query(service, account) as CFDictionary, attributes as CFDictionary)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

struct ProjectKeychainModule: BuiltinModule {
    let name = "SwiftPouchProjectKeychain"
    let projectID: ProjectID
    let backend: any ProjectKeychainBackend

    func register(into interpreter: Interpreter) {
        let constants: [String: Value] = [
            "kSecClass": .string(kSecClass as String),
            "kSecClassGenericPassword": .string(kSecClassGenericPassword as String),
            "kSecAttrService": .string(kSecAttrService as String),
            "kSecAttrAccount": .string(kSecAttrAccount as String),
            "kSecReturnData": .string(kSecReturnData as String),
            "kSecMatchLimit": .string(kSecMatchLimit as String),
            "kSecMatchLimitOne": .string(kSecMatchLimitOne as String),
            "kSecValueData": .string(kSecValueData as String),
            "kSecAttrAccessible": .string(kSecAttrAccessible as String),
            "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly": .string(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
            "errSecSuccess": .int(Int(errSecSuccess)),
            "errSecItemNotFound": .int(Int(errSecItemNotFound)),
            "NSOSStatusErrorDomain": .string(NSOSStatusErrorDomain)
        ]
        for (name, value) in constants {
            interpreter.rootScope.bind(name, value: value, mutable: false)
        }

        // Foundation's generated surface does not include this two-argument
        // convenience initializer used by the credential store's error paths.
        interpreter.bridges["init NSError(domain:code:)"] = .`init` { args in
            guard args.count == 2, case .string(let domain) = args[0],
                  case .int(let code) = args[1] else {
                throw RuntimeError.invalid("NSError(domain:code:) requires a String and Int")
            }
            return .opaque(typeName: "NSError", value: NSError(domain: domain, code: code))
        }

        interpreter.registerGlobal(name: "SecItemCopyMatching") { args in
            guard args.count == 1, let key = self.key(for: args[0], operation: .copy) else {
                return .tuple([.int(Int(errSecParam)), .optional(nil)])
            }
            let (status, data) = self.backend.copy(service: key.service, account: key.account)
            let result: Value = data.map { .optional(.opaque(typeName: "Data", value: $0)) } ?? .optional(nil)
            return .tuple([.int(Int(status)), result])
        }
        interpreter.registerGlobal(name: "SecItemAdd") { args in
            guard args.count == 2, self.isNil(args[1]),
                  let key = self.key(for: args[0], operation: .add), let data = key.data else {
                return .int(Int(errSecParam))
            }
            return .int(Int(self.backend.add(service: key.service, account: key.account, data: data)))
        }
        interpreter.registerGlobal(name: "SecItemUpdate") { args in
            guard args.count == 2, let key = self.key(for: args[0], operation: .lookup),
                  let attributes = self.fields(args[1], required: [kSecValueData as String,
                                                               kSecAttrAccessible as String]),
                  let data = self.binary(attributes[kSecValueData as String]),
                  self.isString(attributes[kSecAttrAccessible as String], kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            else { return .int(Int(errSecParam)) }
            return .int(Int(self.backend.update(service: key.service, account: key.account, data: data)))
        }
        interpreter.registerGlobal(name: "SecItemDelete") { args in
            guard args.count == 1, let key = self.key(for: args[0], operation: .lookup) else {
                return .int(Int(errSecParam))
            }
            return .int(Int(self.backend.delete(service: key.service, account: key.account)))
        }
    }

    private enum Operation { case copy, add, lookup }

    private func key(for value: Value, operation: Operation) -> (service: String, account: String, data: Data?)? {
        let base: Set<String> = [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String]
        let extra: Set<String>
        switch operation {
        case .copy: extra = [kSecReturnData as String, kSecMatchLimit as String]
        case .add: extra = [kSecValueData as String, kSecAttrAccessible as String]
        case .lookup: extra = []
        }
        guard let attributes = fields(value, required: base.union(extra)),
              isString(attributes[kSecClass as String], kSecClassGenericPassword as String),
              case .string(let service)? = attributes[kSecAttrService as String], !service.isEmpty,
              case .string(let account)? = attributes[kSecAttrAccount as String], !account.isEmpty
        else { return nil }
        switch operation {
        case .copy:
            guard case .bool(true)? = attributes[kSecReturnData as String],
                  isString(attributes[kSecMatchLimit as String], kSecMatchLimitOne as String) else { return nil }
        case .add:
            guard binary(attributes[kSecValueData as String]) != nil,
                  isString(attributes[kSecAttrAccessible as String], kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            else { return nil }
        case .lookup: break
        }
        // The source-controlled service cannot address another project's
        // entries, even if it supplies that project's UUID as an attribute.
        let scopedService = "SwiftPouch.interpreter.\(projectID.directoryName).\(service)"
        return (scopedService, account, binary(attributes[kSecValueData as String]))
    }

    private func fields(_ value: Value, required: Set<String>) -> [String: Value]? {
        guard case .dict(let entries) = value, entries.count == required.count else { return nil }
        var result: [String: Value] = [:]
        for entry in entries {
            guard case .string(let key) = entry.key, required.contains(key), result[key] == nil else { return nil }
            result[key] = entry.value
        }
        return result.count == required.count ? result : nil
    }

    private func isString(_ value: Value?, _ expected: String) -> Bool {
        guard case .string(let string)? = value else { return false }
        return string == expected
    }

    private func binary(_ value: Value?) -> Data? {
        guard case .opaque("Data", let data)? = value else { return nil }
        return data as? Data
    }

    private func isNil(_ value: Value) -> Bool {
        if case .optional(nil) = value { return true }
        return false
    }
}
