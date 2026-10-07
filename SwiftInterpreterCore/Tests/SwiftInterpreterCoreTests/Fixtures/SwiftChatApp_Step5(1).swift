import SwiftUI
import Foundation
import Security
import UIKit

// Für ein iOS-16+-App-Target. Dieser App-Typ muss der einzige @main-Einstiegspunkt im Target sein.

// Schritt 5: startbare Ein-Datei-App auf Basis des in Schritt 4 ausgearbeiteten Fundaments.
// Der Codex-Backend-Endpunkt ist eine interne, veränderliche Schnittstelle.

 // MARK: - Datenmodell

enum ChatRole: String, Codable, Equatable { case user, assistant }
enum MessageStatus: String, Codable, Equatable { case completed, streaming, interrupted, failed, cancelled }
enum ModelOrigin: String, Codable, Equatable { case discovered, manual }
enum ModelAvailability: String, Codable, Equatable { case available, unknown, unavailable }

struct ModelDefinition: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var origin: ModelOrigin
    var availability: ModelAvailability
    var supportedReasoningLevels: [String]
}

struct ChatMessage: Identifiable, Codable {
    var id: UUID
    var role: ChatRole
    var text: String
    var createdAt: Date
    var status: MessageStatus
    var requestID: UUID
    var generationID: UUID
    var modelID: String?
    var reasoningLevel: String?
    var retryOfMessageID: UUID?
    var failureMessage: String?
}

struct ChatConversation: Identifiable, Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelID: String?
    var reasoningLevel: String?
    var messages: [ChatMessage]
}

struct ChatPreferences: Codable {
    var selectedModelID: String?
    var reasoningLevel: String?
    var visibleModelIDs: [String]

    init(selectedModelID: String? = nil, reasoningLevel: String? = nil, visibleModelIDs: [String] = []) {
        self.selectedModelID = selectedModelID
        self.reasoningLevel = reasoningLevel
        self.visibleModelIDs = visibleModelIDs
    }
}

struct ChatIndex: Codable {
    var conversationIDs: [UUID]
    var activeConversationID: UUID?
    var preferences: ChatPreferences
    var models: [ModelDefinition]

    init(
        conversationIDs: [UUID] = [],
        activeConversationID: UUID? = nil,
        preferences: ChatPreferences = ChatPreferences(),
        models: [ModelDefinition] = []
    ) {
        self.conversationIDs = conversationIDs
        self.activeConversationID = activeConversationID
        self.preferences = preferences
        self.models = models
    }
}

struct ChatState {
    var conversations: [ChatConversation] = []
    var activeConversationID: UUID?
    var preferences = ChatPreferences()
    var models: [ModelDefinition] = []
    var activeGenerationID: UUID?

    var activeConversation: ChatConversation? {
        guard let id = activeConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    var visibleModels: [ModelDefinition] {
        let usable = models.filter { $0.availability != .unavailable }
        guard !preferences.visibleModelIDs.isEmpty else { return usable }
        return usable.filter { preferences.visibleModelIDs.contains($0.id) }
    }

    var selectedModelName: String {
        guard let id = preferences.selectedModelID else { return "Modell wählen" }
        return models.first { $0.id == id }?.name ?? id
    }
}

struct ChatRequest {
    var requestID: UUID
    var generationID: UUID
    var conversationID: UUID
    var userMessageID: UUID
    var assistantMessageID: UUID
    var modelID: String?
    var reasoningLevel: String?
    var context: [ChatMessage]
}

// MARK: - Lokale JSON-Speicherung

protocol ChatPersistence {
    func loadIndex() throws -> ChatIndex
    func loadConversation(id: UUID) throws -> ChatConversation?
    func saveIndex(_ index: ChatIndex) throws
    func saveConversation(_ conversation: ChatConversation) throws
    func deleteConversation(id: UUID) throws
}

final class JSONChatPersistence: ChatPersistence {
    private let rootURL: URL
    private let fileManager = FileManager.default

    init(rootURL: URL) { self.rootURL = rootURL }

    static func makeDefault() -> ChatPersistence {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return MemoryChatPersistence()
        }
        return JSONChatPersistence(rootURL: support.appendingPathComponent("SwiftChat", isDirectory: true))
    }

    func loadIndex() throws -> ChatIndex {
        let url = rootURL.appendingPathComponent("index.json")
        guard fileManager.fileExists(atPath: url.path) else { return ChatIndex() }
        return try JSONDecoder().decode(ChatIndex.self, from: Data(contentsOf: url))
    }

    func loadConversation(id: UUID) throws -> ChatConversation? {
        let url = conversationURL(id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ChatConversation.self, from: Data(contentsOf: url))
    }

    func saveIndex(_ index: ChatIndex) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(index)
        try data.write(to: rootURL.appendingPathComponent("index.json"), options: .atomic)
    }

    func saveConversation(_ conversation: ChatConversation) throws {
        let folder = rootURL.appendingPathComponent("Conversations", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(conversation)
        try data.write(to: conversationURL(conversation.id), options: .atomic)
    }

    func deleteConversation(id: UUID) throws {
        let url = conversationURL(id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func conversationURL(_ id: UUID) -> URL {
        rootURL
            .appendingPathComponent("Conversations", isDirectory: true)
            .appendingPathComponent("conversation-\(id.uuidString).json")
    }
}

final class MemoryChatPersistence: ChatPersistence {
    private var index = ChatIndex()
    private var conversations: [UUID: ChatConversation] = [:]

    func loadIndex() throws -> ChatIndex { index }
    func loadConversation(id: UUID) throws -> ChatConversation? { conversations[id] }
    func saveIndex(_ index: ChatIndex) throws { self.index = index }
    func saveConversation(_ conversation: ChatConversation) throws { conversations[conversation.id] = conversation }
    func deleteConversation(id: UUID) throws { conversations.removeValue(forKey: id) }
}

// MARK: - Anmeldung und sichere Zugangsdaten

struct DeviceLoginChallenge: Identifiable {
    var verificationURL: URL
    var userCode: String
    var expiresAt: Date
    var pollingInterval: TimeInterval
    var id: String { userCode }
}

struct CodexAccount {
    var accountID: String
    var displayName: String?
    var planName: String?
}

struct CodexCredentials: Codable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String
    var displayName: String?
    var planName: String?
    var expiresAt: Date?
}

enum CodexAuthState: Equatable {
    case signedOut
    case requestingCode
    case waitingForApproval
    case connected
    case refreshing
    case failed(String)
}

enum CodexAuthError: Error {
    case cancelled
    case expired
    case unauthorized
    case transport(String)
}

extension CodexAuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Anmeldung abgebrochen."
        case .expired: return "Der Anmeldecode ist abgelaufen. Bitte starte die Anmeldung erneut."
        case .unauthorized: return "Die Codex-Anmeldung ist ungültig oder abgelaufen. Bitte melde dich erneut an."
        case .transport(let message): return message
        }
    }
}

protocol SecureCredentialStore {
    func readCredentials() throws -> CodexCredentials?
    func saveCredentials(_ credentials: CodexCredentials) throws
    func deleteCredentials() throws
}

final class KeychainCredentialStore: SecureCredentialStore {
    private let service = Bundle.main.bundleIdentifier.map { $0 + ".codex-session" } ?? "SwiftChat.codex-session"
    private let account = "oauth"

    func readCredentials() throws -> CodexCredentials? {
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
        return try JSONDecoder().decode(CodexCredentials.self, from: data)
    }

    func saveCredentials(_ credentials: CodexCredentials) throws {
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

protocol CancellableOperation { func cancel() }

private enum CodexOAuth {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let accountsBase = URL(string: "https://auth.openai.com/api/accounts")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    static let redirectURI = "https://auth.openai.com/deviceauth/callback"
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func formEscape(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "%20", with: "+") ?? value
}

private func formBody(_ fields: [String: String]) -> Data {
    let body = fields.keys.sorted().map { "\(formEscape($0))=\(formEscape(fields[$0] ?? ""))" }.joined(separator: "&")
    return Data(body.utf8)
}

private func tokenClaims(_ token: String?) -> [String: Any] {
    guard let token = token else { return [:] }
    let parts = token.split(separator: ".")
    guard parts.count > 1 else { return [:] }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded.append("=") }
    guard let data = Data(base64Encoded: encoded), let object = jsonObject(data) else { return [:] }
    return object
}

private func accountFields(idToken: String?, accessToken: String?) -> (id: String?, name: String?, plan: String?) {
    let claims = tokenClaims(idToken).isEmpty ? tokenClaims(accessToken) : tokenClaims(idToken)
    let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
    let accountID = (auth["chatgpt_account_id"] as? String)
        ?? (auth["account_id"] as? String)
        ?? (claims["chatgpt_account_id"] as? String)
        ?? (claims["account_id"] as? String)
    let name = (claims["name"] as? String) ?? (claims["email"] as? String)
    let plan = (auth["chatgpt_plan_type"] as? String) ?? (claims["chatgpt_plan_type"] as? String)
    return (accountID, name, plan)
}

final class DeviceCodeLoginOperation: CancellableOperation {
    private let queue = DispatchQueue(label: "SwiftChat.device-login")
    private let session = URLSession(configuration: .ephemeral)
    private let credentialStore: SecureCredentialStore
    private let onChallenge: (DeviceLoginChallenge) -> Void
    private let completion: (Result<CodexAccount, CodexAuthError>) -> Void
    private var task: URLSessionDataTask?
    private var pollWork: DispatchWorkItem?
    private var finished = false
    private var deviceAuthID = ""
    private var userCode = ""
    private var interval: TimeInterval = 5
    private var expiresAt = Date().addingTimeInterval(15 * 60)

    init(
        credentialStore: SecureCredentialStore,
        onChallenge: @escaping (DeviceLoginChallenge) -> Void,
        completion: @escaping (Result<CodexAccount, CodexAuthError>) -> Void
    ) {
        self.credentialStore = credentialStore
        self.onChallenge = onChallenge
        self.completion = completion
    }

    func start() { queue.async { self.requestUserCode() } }

    func cancel() {
        queue.async {
            guard !self.finished else { return }
            self.task?.cancel()
            self.pollWork?.cancel()
            self.finish(.failure(.cancelled))
        }
    }

    private func requestUserCode() {
        let url = CodexOAuth.accountsBase.appendingPathComponent("deviceauth").appendingPathComponent("usercode")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["client_id": CodexOAuth.clientID])
        send(request) { status, data, error in
            guard error == nil, let data = data else {
                self.finish(.failure(.transport(error?.localizedDescription ?? "Anmeldecode konnte nicht angefordert werden.")))
                return
            }
            guard (200..<300).contains(status), let json = jsonObject(data),
                  let deviceID = json["device_auth_id"] as? String,
                  let code = (json["user_code"] as? String) ?? (json["usercode"] as? String) else {
                self.finish(.failure(.transport(Self.serverMessage(data, status: status))))
                return
            }
            self.deviceAuthID = deviceID
            self.userCode = code
            if let value = json["interval"] as? Double { self.interval = max(1, value) }
            if let value = json["interval"] as? String, let seconds = Double(value) { self.interval = max(1, seconds) }
            self.expiresAt = Date().addingTimeInterval(15 * 60)
            self.onChallenge(DeviceLoginChallenge(
                verificationURL: CodexOAuth.verificationURL,
                userCode: code,
                expiresAt: self.expiresAt,
                pollingInterval: self.interval
            ))
            self.schedulePoll()
        }
    }

    private func schedulePoll() {
        guard !finished else { return }
        guard Date() < expiresAt else { finish(.failure(.expired)); return }
        let work = DispatchWorkItem { [weak self] in self?.pollForApproval() }
        pollWork = work
        queue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func pollForApproval() {
        guard !finished else { return }
        let url = CodexOAuth.accountsBase.appendingPathComponent("deviceauth").appendingPathComponent("token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_auth_id": deviceAuthID,
            "user_code": userCode
        ])
        send(request) { status, data, error in
            guard error == nil, let data = data else {
                self.finish(.failure(.transport(error?.localizedDescription ?? "Anmeldestatus konnte nicht geprüft werden.")))
                return
            }
            if (200..<300).contains(status), let json = jsonObject(data),
               let code = json["authorization_code"] as? String,
               let verifier = json["code_verifier"] as? String {
                let challenge = json["code_challenge"] as? String ?? ""
                self.exchangeAuthorizationCode(code, verifier: verifier, challenge: challenge)
            } else if status == 403 || status == 404 {
                self.schedulePoll()
            } else {
                self.finish(.failure(.transport(Self.serverMessage(data, status: status))))
            }
        }
    }

    private func exchangeAuthorizationCode(_ code: String, verifier: String, challenge: String) {
        var request = URLRequest(url: CodexOAuth.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": CodexOAuth.redirectURI,
            "client_id": CodexOAuth.clientID,
            "code_verifier": verifier,
            "code_challenge": challenge
        ])
        send(request) { status, data, error in
            guard error == nil, let data = data else {
                self.finish(.failure(.transport(error?.localizedDescription ?? "Token konnte nicht angefordert werden.")))
                return
            }
            guard (200..<300).contains(status), let json = jsonObject(data),
                  let accessToken = json["access_token"] as? String else {
                self.finish(.failure(.transport(Self.serverMessage(data, status: status))))
                return
            }
            let idToken = json["id_token"] as? String
            let fields = accountFields(idToken: idToken, accessToken: accessToken)
            guard let accountID = fields.id, !accountID.isEmpty else {
                self.finish(.failure(.unauthorized))
                return
            }
            let expiresIn = json["expires_in"] as? Double ?? 3600
            let credentials = CodexCredentials(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                idToken: idToken,
                accountID: accountID,
                displayName: fields.name,
                planName: fields.plan,
                expiresAt: Date().addingTimeInterval(expiresIn)
            )
            do {
                try self.credentialStore.saveCredentials(credentials)
                self.finish(.success(CodexAccount(accountID: accountID, displayName: fields.name, planName: fields.plan)))
            } catch {
                self.finish(.failure(.transport("Anmeldedaten konnten nicht sicher gespeichert werden: \(error.localizedDescription)")))
            }
        }
    }

    private func send(_ request: URLRequest, completion: @escaping (Int, Data?, Error?) -> Void) {
        guard !finished else { return }
        let nextTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                guard !self.finished else { return }
                self.task = nil
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(status, data, error)
            }
        }
        task = nextTask
        nextTask.resume()
    }

    private func finish(_ result: Result<CodexAccount, CodexAuthError>) {
        guard !finished else { return }
        finished = true
        pollWork?.cancel()
        task?.cancel()
        session.invalidateAndCancel()
        completion(result)
    }

    private static func serverMessage(_ data: Data, status: Int) -> String {
        if let json = jsonObject(data) {
            let message = (json["error_description"] as? String)
                ?? (json["message"] as? String)
                ?? (json["error"] as? String)
            if let message = message, !message.isEmpty { return "Anmeldung fehlgeschlagen (\(status)): \(message)" }
        }
        return "Anmeldung fehlgeschlagen (HTTP \(status))."
    }
}

final class CodexSessionManager: ObservableObject {
    @Published private(set) var state: CodexAuthState = .signedOut
    @Published private(set) var account: CodexAccount?
    @Published private(set) var challenge: DeviceLoginChallenge?
    @Published private(set) var lastError: String?

    private let credentialStore: SecureCredentialStore
    private let authQueue = DispatchQueue(label: "SwiftChat.credentials")
    private var loginOperation: DeviceCodeLoginOperation?
    private var pendingCredentialCallbacks: [(Result<CodexCredentials, CodexAuthError>) -> Void] = []
    private var refreshInFlight = false
    private var authEpoch = 0
    private var loginEpoch = 0

    init(credentialStore: SecureCredentialStore = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
        do {
            if let credentials = try credentialStore.readCredentials() {
                account = CodexAccount(accountID: credentials.accountID, displayName: credentials.displayName, planName: credentials.planName)
                state = .connected
            }
        } catch {
            lastError = "Gespeicherte Anmeldung konnte nicht gelesen werden: \(error.localizedDescription)"
        }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        if case .refreshing = state { return true }
        return false
    }

    func startLogin() {
        guard loginOperation == nil else { return }
        loginEpoch += 1
        let requestEpoch = loginEpoch
        state = .requestingCode
        lastError = nil
        let operation = DeviceCodeLoginOperation(
            credentialStore: credentialStore,
            onChallenge: { [weak self] challenge in
                DispatchQueue.main.async {
                    guard let self = self, self.loginEpoch == requestEpoch else { return }
                    self.challenge = challenge
                    self.state = .waitingForApproval
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard self.loginEpoch == requestEpoch else { return }
                    self.loginOperation = nil
                    self.challenge = nil
                    switch result {
                    case .success(let account):
                        self.account = account
                        self.state = .connected
                        self.lastError = nil
                    case .failure(.cancelled):
                        self.state = .signedOut
                    case .failure(let error):
                        self.state = .failed(error.localizedDescription)
                        self.lastError = error.localizedDescription
                    }
                }
            }
        )
        loginOperation = operation
        operation.start()
    }

    func cancelLogin() {
        loginEpoch += 1
        loginOperation?.cancel()
        loginOperation = nil
        challenge = nil
        state = .signedOut
    }

    func signOut() {
        loginEpoch += 1
        loginOperation?.cancel()
        loginOperation = nil
        challenge = nil
        account = nil
        state = .signedOut
        authQueue.async {
            self.authEpoch += 1
            self.refreshInFlight = false
            let callbacks = self.pendingCredentialCallbacks
            self.pendingCredentialCallbacks.removeAll()
            do { try self.credentialStore.deleteCredentials() }
            catch {
                DispatchQueue.main.async {
                    self.lastError = "Anmeldedaten konnten nicht gelöscht werden: \(error.localizedDescription)"
                }
            }
            callbacks.forEach { $0(.failure(.unauthorized)) }
        }
    }

    func validCredentials(completion: @escaping (Result<CodexCredentials, CodexAuthError>) -> Void) {
        authQueue.async {
            do {
                guard let credentials = try self.credentialStore.readCredentials() else {
                    completion(.failure(.unauthorized))
                    return
                }
                if let expiry = credentials.expiresAt, expiry.timeIntervalSinceNow < 120 {
                    guard credentials.refreshToken != nil else {
                        completion(.failure(.unauthorized))
                        return
                    }
                    self.pendingCredentialCallbacks.append(completion)
                    if !self.refreshInFlight { self.beginRefresh(using: credentials) }
                } else {
                    completion(.success(credentials))
                }
            } catch {
                completion(.failure(.transport(error.localizedDescription)))
            }
        }
    }

    private func beginRefresh(using old: CodexCredentials) {
        guard let refreshToken = old.refreshToken else {
            finishRefresh(.failure(.unauthorized))
            return
        }
        refreshInFlight = true
        let requestEpoch = authEpoch
        DispatchQueue.main.async { self.state = .refreshing }
        var request = URLRequest(url: CodexOAuth.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": CodexOAuth.clientID
        ])
        URLSession.shared.dataTask(with: request) { data, response, error in
            self.authQueue.async {
                guard requestEpoch == self.authEpoch else { return }
                if let error = error {
                    self.finishRefresh(.failure(.transport(error.localizedDescription)))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status), let data = data, let json = jsonObject(data),
                      let accessToken = json["access_token"] as? String else {
                    if status == 400 || status == 401 {
                        try? self.credentialStore.deleteCredentials()
                        self.finishRefresh(.failure(.unauthorized))
                    } else {
                        self.finishRefresh(.failure(.transport("Token-Erneuerung fehlgeschlagen (HTTP \(status)).")))
                    }
                    return
                }
                let idToken = (json["id_token"] as? String) ?? old.idToken
                let fields = accountFields(idToken: idToken, accessToken: accessToken)
                let newAccountID = fields.id ?? old.accountID
                guard newAccountID == old.accountID else {
                    try? self.credentialStore.deleteCredentials()
                    self.finishRefresh(.failure(.unauthorized))
                    return
                }
                let expiresIn = json["expires_in"] as? Double ?? 3600
                let updated = CodexCredentials(
                    accessToken: accessToken,
                    refreshToken: (json["refresh_token"] as? String) ?? refreshToken,
                    idToken: idToken,
                    accountID: old.accountID,
                    displayName: fields.name ?? old.displayName,
                    planName: fields.plan ?? old.planName,
                    expiresAt: Date().addingTimeInterval(expiresIn)
                )
                do {
                    try self.credentialStore.saveCredentials(updated)
                    self.finishRefresh(.success(updated))
                } catch {
                    self.finishRefresh(.failure(.transport("Erneuerte Anmeldung konnte nicht gespeichert werden: \(error.localizedDescription)")))
                }
            }
        }.resume()
    }

    private func finishRefresh(_ result: Result<CodexCredentials, CodexAuthError>) {
        refreshInFlight = false
        let callbacks = pendingCredentialCallbacks
        pendingCredentialCallbacks.removeAll()
        switch result {
        case .success(let credentials):
            DispatchQueue.main.async {
                self.account = CodexAccount(accountID: credentials.accountID, displayName: credentials.displayName, planName: credentials.planName)
                self.state = .connected
            }
        case .failure(let error):
            DispatchQueue.main.async {
                self.state = .failed(error.localizedDescription)
                self.lastError = error.localizedDescription
            }
        }
        callbacks.forEach { $0(result) }
    }
}

// MARK: - Codex Chat-API und SSE

enum ChatProviderError: Error {
    case notConfigured
    case unauthorized
    case transport(String)
    case server(String)
    case malformedStream
}

extension ChatProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Bitte wähle zuerst ein verfügbares Modell aus."
        case .unauthorized: return "Codex ist nicht angemeldet. Verbinde dein ChatGPT-Konto in den Einstellungen."
        case .transport(let message): return message
        case .server(let message): return message
        case .malformedStream: return "Die Antwort wurde beendet, bevor Codex den Stream abgeschlossen hat."
        }
    }
}

enum ChatProviderEvent { case textDelta(String) }
protocol ChatStreamHandle: CancellableOperation {}

protocol ChatProvider {
    func loadModels(completion: @escaping (Result<[ModelDefinition], ChatProviderError>) -> Void)
    func stream(
        _ request: ChatRequest,
        onEvent: @escaping (ChatProviderEvent) -> Void,
        completion: @escaping (Result<Void, ChatProviderError>) -> Void
    ) -> ChatStreamHandle
}

private enum CodexAPI {
    static let baseURL = URL(string: "https://chatgpt.com/backend-api/codex")!

    static func authorizedRequest(url: URL, credentials: CodexCredentials) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex", forHTTPHeaderField: "OAI-Product-Sku")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func models(from data: Data) -> [ModelDefinition] {
        guard let root = jsonObject(data) else { return [] }
        let rows = (root["models"] as? [[String: Any]]) ?? (root["data"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = (row["slug"] as? String) ?? (row["id"] as? String), !id.isEmpty else { return nil }
            let name = (row["display_name"] as? String) ?? (row["name"] as? String) ?? id
            let apiSupported = row["supported_in_api"] as? Bool ?? true
            let visibility = ((row["visibility"] as? String) ?? "").lowercased()
            let availability: ModelAvailability = (!apiSupported || visibility == "hidden" || visibility == "none") ? .unavailable : .available
            let rawLevels = row["supported_reasoning_levels"] as? [Any] ?? []
            let levels = rawLevels.compactMap { item -> String? in
                if let value = item as? String { return value }
                if let object = item as? [String: Any] {
                    return (object["effort"] as? String) ?? (object["reasoning_effort"] as? String) ?? (object["id"] as? String)
                }
                return nil
            }
            return ModelDefinition(id: id, name: name, origin: .discovered, availability: availability, supportedReasoningLevels: levels)
        }
    }

    static func errorMessage(_ data: Data, status: Int) -> String {
        if let json = jsonObject(data) {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return "Codex (HTTP \(status)): \(message)"
            }
            if let message = json["message"] as? String { return "Codex (HTTP \(status)): \(message)" }
        }
        return "Codex-Anfrage fehlgeschlagen (HTTP \(status))."
    }
}

final class CodexChatProvider: ChatProvider {
    private let sessionManager: CodexSessionManager

    init(session: CodexSessionManager) { self.sessionManager = session }

    func loadModels(completion: @escaping (Result<[ModelDefinition], ChatProviderError>) -> Void) {
        sessionManager.validCredentials { result in
            switch result {
            case .failure:
                completion(.failure(.unauthorized))
            case .success(let credentials):
                var components = URLComponents(url: CodexAPI.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "client_version", value: "1.0.0")]
                guard let url = components?.url else {
                    completion(.failure(.transport("Modelladresse konnte nicht erstellt werden.")))
                    return
                }
                let request = CodexAPI.authorizedRequest(url: url, credentials: credentials)
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error = error {
                        completion(.failure(.transport(error.localizedDescription)))
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status), let data = data else {
                        completion(.failure(status == 401 ? .unauthorized : .server(CodexAPI.errorMessage(data ?? Data(), status: status))))
                        return
                    }
                    let models = CodexAPI.models(from: data)
                    guard !models.isEmpty else {
                        completion(.failure(.server("Codex hat keine nutzbaren Modelle geliefert.")))
                        return
                    }
                    completion(.success(models))
                }.resume()
            }
        }
    }

    func stream(
        _ request: ChatRequest,
        onEvent: @escaping (ChatProviderEvent) -> Void,
        completion: @escaping (Result<Void, ChatProviderError>) -> Void
    ) -> ChatStreamHandle {
        let handle = DeferredStreamHandle()
        guard let modelID = request.modelID, !modelID.isEmpty else {
            completion(.failure(.notConfigured))
            return handle
        }
        sessionManager.validCredentials { result in
            switch result {
            case .failure:
                handle.finish(.failure(.unauthorized), completion: completion)
            case .success(let credentials):
                var urlRequest = CodexAPI.authorizedRequest(
                    url: CodexAPI.baseURL.appendingPathComponent("responses"),
                    credentials: credentials
                )
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let context = request.context.compactMap { message -> [String: Any]? in
                    if message.role == .assistant && message.status != .completed { return nil }
                    if message.text.isEmpty { return nil }
                    return ["role": message.role.rawValue, "content": message.text]
                }
                var body: [String: Any] = [
                    "model": modelID,
                    "input": context,
                    "stream": true,
                    "store": false
                ]
                if let effort = request.reasoningLevel, !effort.isEmpty {
                    body["reasoning"] = ["effort": effort]
                }
                do {
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    handle.finish(.failure(.transport("Anfrage konnte nicht erstellt werden: \(error.localizedDescription)")), completion: completion)
                    return
                }
                let operation = CodexSSEStreamOperation(request: urlRequest, onEvent: onEvent) { result in
                    handle.finish(result, completion: completion)
                }
                guard handle.attach(operation) else { return }
                operation.start()
            }
        }
        return handle
    }
}

private final class DeferredStreamHandle: ChatStreamHandle {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var inner: ChatStreamHandle?

    func attach(_ operation: ChatStreamHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !completed else { operation.cancel(); return false }
        inner = operation
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let operation = inner
        lock.unlock()
        operation?.cancel()
    }

    func finish(
        _ result: Result<Void, ChatProviderError>,
        completion: @escaping (Result<Void, ChatProviderError>) -> Void
    ) {
        lock.lock()
        guard !cancelled, !completed else { lock.unlock(); return }
        completed = true
        inner = nil
        lock.unlock()
        completion(result)
    }
}

private final class CodexSSEStreamOperation: NSObject, ChatStreamHandle, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let request: URLRequest
    private let onEvent: (ChatProviderEvent) -> Void
    private let completion: (Result<Void, ChatProviderError>) -> Void
    private let lock = NSLock()
    private var isFinished = false
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var statusCode = 0
    private var lineBuffer = Data()
    private var responseBody = Data()
    private var eventName = ""
    private var eventData: [String] = []
    private var receivedTerminalEvent = false

    init(
        request: URLRequest,
        onEvent: @escaping (ChatProviderEvent) -> Void,
        completion: @escaping (Result<Void, ChatProviderError>) -> Void
    ) {
        self.request = request
        self.onEvent = onEvent
        self.completion = completion
    }

    func start() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let task = self.task
        let session = self.session
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finishedSnapshot() else { return }
        if !(200..<300).contains(statusCode) {
            responseBody.append(data)
            return
        }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 10) {
            let lineData = Data(lineBuffer[..<newline])
            let next = lineBuffer.index(after: newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex..<next)
            processLine(lineData)
            if finishedSnapshot() { return }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if finishedSnapshot() {
            session.finishTasksAndInvalidate()
            return
        }
        if !lineBuffer.isEmpty {
            processLine(lineBuffer)
            lineBuffer.removeAll()
        }
        if !eventData.isEmpty { processCurrentEvent() }
        if let error = error {
            finish(.failure(.transport(error.localizedDescription)))
        } else if !(200..<300).contains(statusCode) {
            finish(.failure(statusCode == 401 ? .unauthorized : .server(CodexAPI.errorMessage(responseBody, status: statusCode))))
        } else if receivedTerminalEvent {
            finish(.success(()))
        } else {
            finish(.failure(.malformedStream))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        self.session = nil
        self.task = nil
        lock.unlock()
    }

    private func processLine(_ data: Data) {
        var lineData = data
        if lineData.last == 13 { lineData.removeLast() }
        guard let line = String(data: lineData, encoding: .utf8) else { return }
        if line.isEmpty {
            processCurrentEvent()
        } else if line.hasPrefix("event:") {
            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            eventData.append(value)
        }
    }

    private func processCurrentEvent() {
        defer { eventName = ""; eventData.removeAll() }
        guard !eventData.isEmpty else { return }
        let payload = eventData.joined(separator: "\n")
        if payload == "[DONE]" {
            receivedTerminalEvent = true
            finish(.success(()))
            return
        }
        guard let data = payload.data(using: .utf8),
              let json = jsonObject(data) else { return }
        let type = eventName.isEmpty ? (json["type"] as? String ?? "") : eventName
        if type == "response.output_text.delta", let delta = json["delta"] as? String {
            onEvent(.textDelta(delta))
        } else if type == "response.completed" {
            receivedTerminalEvent = true
            finish(.success(()))
        } else if type == "response.failed" || type == "response.incomplete" || type == "error" {
            let response = json["response"] as? [String: Any]
            let error = (json["error"] as? [String: Any]) ?? (response?["error"] as? [String: Any])
            let message = (error?["message"] as? String) ?? (json["message"] as? String) ?? "Codex konnte die Antwort nicht abschließen."
            finish(.failure(.server(message)))
        }
    }

    private func finishedSnapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    private func finish(_ result: Result<Void, ChatProviderError>) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        lock.unlock()
        completion(result)
    }
}

// MARK: - Chat-Zustand und Generierungsablauf

final class ChatStore: ObservableObject {
    @Published private(set) var state = ChatState()
    @Published private(set) var persistenceError: String?
    @Published private(set) var providerError: String?

    private let persistence: ChatPersistence
    private var provider: ChatProvider?
    private var loadError: String?
    private var conversationSaveError: String?
    private var indexSaveError: String?
    private var lastConversationWrite: [UUID: Date] = [:]
    private let persistenceInterval: TimeInterval = 0.4

    lazy var generations = GenerationCoordinator(store: self, provider: provider)

    init(persistence: ChatPersistence = JSONChatPersistence.makeDefault(), provider: ChatProvider? = nil) {
        self.persistence = persistence
        self.provider = provider
        do {
            let index = try persistence.loadIndex()
            var loaded = ChatState()
            loaded.preferences = index.preferences
            loaded.models = index.models
            loaded.activeConversationID = index.activeConversationID
            for id in index.conversationIDs {
                if let conversation = try persistence.loadConversation(id: id) { loaded.conversations.append(conversation) }
            }
            if let activeID = loaded.activeConversationID,
               !loaded.conversations.contains(where: { $0.id == activeID }) {
                loaded.activeConversationID = nil
            }
            if loaded.activeConversationID == nil {
                loaded.activeConversationID = loaded.conversations.first?.id
            }
            state = loaded
        } catch {
            loadError = error.localizedDescription
            refreshPersistenceError()
        }
        recoverInterruptedGenerations()
    }

    var isGenerating: Bool { state.activeGenerationID != nil }
    var activeConversation: ChatConversation? { state.activeConversation }
    var visibleModels: [ModelDefinition] { state.visibleModels }
    var selectedModelName: String { state.selectedModelName }

    @discardableResult
    func createConversation() -> UUID {
        let now = Date()
        let conversation = ChatConversation(
            id: UUID(),
            title: "Neuer Chat",
            createdAt: now,
            updatedAt: now,
            modelID: state.preferences.selectedModelID,
            reasoningLevel: state.preferences.reasoningLevel,
            messages: []
        )
        var next = state
        next.conversations.insert(conversation, at: 0)
        next.activeConversationID = conversation.id
        state = next
        persistConversation(id: conversation.id, force: true)
        persistIndex()
        return conversation.id
    }

    func selectConversation(id: UUID) {
        guard state.conversations.contains(where: { $0.id == id }) else { return }
        var next = state
        next.activeConversationID = id
        state = next
        persistIndex()
    }

    func deleteConversation(id: UUID) {
        if let generationID = state.activeGenerationID,
           state.conversations.first(where: { $0.id == id })?.messages.contains(where: { $0.generationID == generationID }) == true {
            generations.cancel()
        }
        var next = state
        next.conversations.removeAll { $0.id == id }
        if next.activeConversationID == id { next.activeConversationID = next.conversations.first?.id }
        state = next
        do { try persistence.deleteConversation(id: id) }
        catch { conversationSaveError = error.localizedDescription }
        persistIndex()
        refreshPersistenceError()
    }

    func selectModel(id: String) {
        guard state.models.contains(where: { $0.id == id && $0.availability != .unavailable }) else { return }
        var next = state
        next.preferences.selectedModelID = id
        state = next
        persistIndex()
    }

    func setReasoningLevel(_ value: String?) {
        var next = state
        next.preferences.reasoningLevel = value
        state = next
        persistIndex()
    }

    func setVisibleModelIDs(_ ids: [String]) {
        var next = state
        next.preferences.visibleModelIDs = ids
        state = next
        persistIndex()
    }

    func addManualModel(id rawID: String) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !state.models.contains(where: { $0.id == id }) else { return }
        var next = state
        next.models.append(ModelDefinition(
            id: id,
            name: id,
            origin: .manual,
            availability: .unknown,
            supportedReasoningLevels: ["low", "medium", "high"]
        ))
        next.preferences.selectedModelID = id
        state = next
        persistIndex()
    }

    func updateModelCatalog(_ discovered: [ModelDefinition]) {
        var next = state
        let manual = next.models.filter { $0.origin == .manual }
        var merged = discovered
        for model in manual where !merged.contains(where: { $0.id == model.id }) { merged.append(model) }
        next.models = merged
        if let selected = next.preferences.selectedModelID,
           !merged.contains(where: { $0.id == selected && $0.availability != .unavailable }) {
            next.preferences.selectedModelID = nil
        }
        state = next
        persistIndex()
    }

    func attachProvider(_ provider: ChatProvider?) {
        self.provider = provider
        generations.attachProvider(provider)
        if provider != nil { refreshModelCatalog() }
    }

    func refreshModelCatalog() {
        guard let provider = provider else { return }
        provider.loadModels { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let models):
                    self.providerError = nil
                    self.updateModelCatalog(models)
                case .failure(let error):
                    self.providerError = error.localizedDescription
                }
            }
        }
    }

    func flush() {
        for conversation in state.conversations { persistConversation(id: conversation.id, force: true) }
        persistIndex()
    }

    func beginGeneration(prompt: String) -> ChatRequest? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state.activeGenerationID == nil else { return nil }
        guard let modelID = state.preferences.selectedModelID else {
            providerError = ChatProviderError.notConfigured.localizedDescription
            return nil
        }
        let conversationID = state.activeConversationID ?? createConversation()
        guard let index = state.conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        let now = Date()
        let requestID = UUID()
        let generationID = UUID()
        let userID = UUID()
        let assistantID = UUID()
        let reasoning = state.preferences.reasoningLevel
        var conversation = state.conversations[index]
        let userMessage = ChatMessage(
            id: userID, role: .user, text: prompt, createdAt: now, status: .completed,
            requestID: requestID, generationID: generationID, modelID: modelID,
            reasoningLevel: reasoning, retryOfMessageID: nil, failureMessage: nil
        )
        var context = conversation.messages
        context.append(userMessage)
        let assistantMessage = ChatMessage(
            id: assistantID, role: .assistant, text: "", createdAt: now, status: .streaming,
            requestID: requestID, generationID: generationID, modelID: modelID,
            reasoningLevel: reasoning, retryOfMessageID: nil, failureMessage: nil
        )
        conversation.messages.append(userMessage)
        conversation.messages.append(assistantMessage)
        conversation.updatedAt = now
        conversation.modelID = modelID
        conversation.reasoningLevel = reasoning
        if conversation.title == "Neuer Chat" {
            conversation.title = String(prompt.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var next = state
        next.conversations[index] = conversation
        next.activeGenerationID = generationID
        state = next
        providerError = nil
        persistConversation(id: conversationID, force: true)
        persistIndex()
        return ChatRequest(
            requestID: requestID, generationID: generationID, conversationID: conversationID,
            userMessageID: userID, assistantMessageID: assistantID, modelID: modelID,
            reasoningLevel: reasoning, context: context
        )
    }

    func canRetry(messageID: UUID) -> Bool {
        guard state.activeGenerationID == nil, let conversation = state.activeConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              index == conversation.messages.count - 1 else { return false }
        let message = conversation.messages[index]
        return message.role == .assistant &&
            (message.status == .interrupted || message.status == .failed || message.status == .cancelled)
    }

    func retry(messageID: UUID) -> ChatRequest? {
        guard canRetry(messageID: messageID), let conversationID = state.activeConversationID,
              let index = state.conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        var conversation = state.conversations[index]
        guard let oldIndex = conversation.messages.firstIndex(where: { $0.id == messageID }),
              let userIndex = conversation.messages[..<oldIndex].lastIndex(where: { $0.role == .user }) else { return nil }
        let previous = conversation.messages[oldIndex]
        let userMessage = conversation.messages[userIndex]
        let requestID = UUID()
        let generationID = UUID()
        let assistantID = UUID()
        let now = Date()
        let modelID = state.preferences.selectedModelID ?? previous.modelID
        guard let modelID = modelID else { return nil }
        let reasoning = state.preferences.reasoningLevel ?? previous.reasoningLevel
        let context = Array(conversation.messages[...userIndex])
        conversation.messages.append(ChatMessage(
            id: assistantID, role: .assistant, text: "", createdAt: now, status: .streaming,
            requestID: requestID, generationID: generationID, modelID: modelID,
            reasoningLevel: reasoning, retryOfMessageID: previous.id, failureMessage: nil
        ))
        conversation.updatedAt = now
        var next = state
        next.conversations[index] = conversation
        next.activeGenerationID = generationID
        state = next
        persistConversation(id: conversationID, force: true)
        persistIndex()
        return ChatRequest(
            requestID: requestID, generationID: generationID, conversationID: conversationID,
            userMessageID: userMessage.id, assistantMessageID: assistantID, modelID: modelID,
            reasoningLevel: reasoning, context: context
        )
    }

    func appendDelta(_ delta: String, generationID: UUID) {
        guard state.activeGenerationID == generationID,
              let conversationIndex = state.conversations.firstIndex(where: { $0.messages.contains(where: { $0.generationID == generationID }) }),
              let messageIndex = state.conversations[conversationIndex].messages.firstIndex(where: {
                  $0.generationID == generationID && $0.role == .assistant && $0.status == .streaming
              }) else { return }
        var next = state
        var conversation = next.conversations[conversationIndex]
        let id = conversation.id
        conversation.messages[messageIndex].text += delta
        conversation.updatedAt = Date()
        next.conversations[conversationIndex] = conversation
        state = next
        persistConversation(id: id, force: false)
    }

    func completeGeneration(_ id: UUID) { finishGeneration(id, status: .completed, failure: nil) }
    func failGeneration(_ id: UUID, message: String) { finishGeneration(id, status: .failed, failure: message) }
    func cancelGeneration(_ id: UUID) { finishGeneration(id, status: .cancelled, failure: nil) }

    private func finishGeneration(_ id: UUID, status: MessageStatus, failure: String?) {
        guard state.activeGenerationID == id,
              let index = state.conversations.firstIndex(where: { $0.messages.contains(where: { $0.generationID == id }) }) else { return }
        var next = state
        var conversation = next.conversations[index]
        let conversationID = conversation.id
        if let messageIndex = conversation.messages.firstIndex(where: { $0.generationID == id && $0.role == .assistant }) {
            conversation.messages[messageIndex].status = status
            conversation.messages[messageIndex].failureMessage = failure
        }
        conversation.updatedAt = Date()
        next.conversations[index] = conversation
        next.activeGenerationID = nil
        state = next
        if let failure = failure { providerError = failure }
        persistConversation(id: conversationID, force: true)
        persistIndex()
    }

    private func recoverInterruptedGenerations() {
        var next = state
        var changed: [UUID] = []
        for i in next.conversations.indices {
            var conversation = next.conversations[i]
            var didChange = false
            for j in conversation.messages.indices where conversation.messages[j].status == .streaming {
                conversation.messages[j].status = .interrupted
                didChange = true
            }
            if didChange {
                conversation.updatedAt = Date()
                next.conversations[i] = conversation
                changed.append(conversation.id)
            }
        }
        guard !changed.isEmpty else { return }
        next.activeGenerationID = nil
        state = next
        changed.forEach { persistConversation(id: $0, force: true) }
        persistIndex()
    }

    private func persistConversation(id: UUID, force: Bool) {
        let now = Date()
        if !force, let previous = lastConversationWrite[id], now.timeIntervalSince(previous) < persistenceInterval { return }
        guard let conversation = state.conversations.first(where: { $0.id == id }) else { return }
        do {
            try persistence.saveConversation(conversation)
            lastConversationWrite[id] = now
            conversationSaveError = nil
        } catch { conversationSaveError = error.localizedDescription }
        refreshPersistenceError()
    }

    private func persistIndex() {
        let index = ChatIndex(
            conversationIDs: state.conversations.map(\.id),
            activeConversationID: state.activeConversationID,
            preferences: state.preferences,
            models: state.models
        )
        do {
            try persistence.saveIndex(index)
            indexSaveError = nil
            loadError = nil
        } catch { indexSaveError = error.localizedDescription }
        refreshPersistenceError()
    }

    private func refreshPersistenceError() {
        persistenceError = loadError ?? conversationSaveError ?? indexSaveError
    }
}

final class GenerationCoordinator {
    private unowned let store: ChatStore
    private var provider: ChatProvider?
    private var activeHandle: ChatStreamHandle?

    init(store: ChatStore, provider: ChatProvider?) {
        self.store = store
        self.provider = provider
    }

    func attachProvider(_ provider: ChatProvider?) { self.provider = provider }

    func send(_ prompt: String) {
        guard let request = store.beginGeneration(prompt: prompt) else { return }
        start(request)
    }

    func retry(messageID: UUID) {
        guard let request = store.retry(messageID: messageID) else { return }
        start(request)
    }

    func cancel() {
        guard let id = store.state.activeGenerationID else { return }
        activeHandle?.cancel()
        activeHandle = nil
        store.cancelGeneration(id)
    }

    private func start(_ request: ChatRequest) {
        guard let provider = provider else {
            store.failGeneration(request.generationID, message: ChatProviderError.unauthorized.localizedDescription)
            return
        }
        let handle = provider.stream(
            request,
            onEvent: { [weak self] event in
                guard case .textDelta(let delta) = event else { return }
                DispatchQueue.main.async { self?.store.appendDelta(delta, generationID: request.generationID) }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self, self.store.state.activeGenerationID == request.generationID else { return }
                    switch result {
                    case .success: self.store.completeGeneration(request.generationID)
                    case .failure(let error): self.store.failGeneration(request.generationID, message: error.localizedDescription)
                    }
                    self.activeHandle = nil
                }
            }
        )
        if store.state.activeGenerationID == request.generationID { activeHandle = handle }
        else { handle.cancel() }
    }
}

// MARK: - SwiftUI-Oberfläche

struct ContentView: View {
    @StateObject private var session: CodexSessionManager
    @StateObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var showingHistory = false
    @State private var showingSettings = false
    @State private var showingAttachmentNotice = false
    @State private var showingVoiceNotice = false

    init() {
        let session = CodexSessionManager()
        _session = StateObject(wrappedValue: session)
        _store = StateObject(wrappedValue: ChatStore(provider: CodexChatProvider(session: session)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = store.persistenceError { NoticeBanner(text: "Speichern: \(error)", symbol: "externaldrive.badge.exclamationmark") }
                if let error = store.providerError { NoticeBanner(text: error, symbol: "exclamationmark.triangle") }
                conversationBody
                ComposerBar(
                    text: $draft,
                    isGenerating: store.isGenerating,
                    canSend: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && store.state.preferences.selectedModelID != nil
                        && session.isConnected,
                    onSend: sendDraft,
                    onCancel: { store.generations.cancel() },
                    onAttachment: { showingAttachmentNotice = true },
                    onVoice: { showingVoiceNotice = true }
                )
            }
            .background(Color(uiColor: .systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: { Image(systemName: "line.3.horizontal") }
                        .accessibilityLabel("Chatverlauf")
                }
                ToolbarItem(placement: .principal) {
                    ModelReasoningMenu(store: store, showingSettings: $showingSettings)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Einstellungen")
                    Button { store.createConversation() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Neuer Chat")
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(store: store)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store, session: session)
        }
        .sheet(item: $session.challenge) { challenge in
            DeviceCodeSheet(challenge: challenge, cancel: { session.cancelLogin() })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert("Anhänge", isPresented: $showingAttachmentNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Datei- und Bildauswahl wird im nächsten Ausbauschritt ergänzt.")
        }
        .alert("Spracheingabe", isPresented: $showingVoiceNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Spracheingabe ist als Platzhalter vorgesehen und noch nicht aktiviert.")
        }
        .onAppear {
            store.attachProvider(CodexChatProvider(session: session))
        }
        .onChange(of: session.state) { state in
            if state == .connected { store.refreshModelCatalog() }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { store.flush() }
        }
    }

    @ViewBuilder
    private var conversationBody: some View {
        if let conversation = store.activeConversation, !conversation.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(conversation.messages) { message in
                            MessageRow(
                                message: message,
                                canRetry: store.canRetry(messageID: message.id),
                                onRetry: { store.generations.retry(messageID: message.id) }
                            )
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
                .onChange(of: conversation.messages.last?.text ?? "") { _ in
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onChange(of: store.state.activeConversationID) { _ in
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
        } else {
            EmptyChatView(isConnected: session.isConnected, selectedModel: store.state.preferences.selectedModelID != nil)
        }
    }

    private func sendDraft() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""
        store.generations.send(message)
    }
}

struct EmptyChatView: View {
    let isConnected: Bool
    let selectedModel: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isConnected ? "sparkles" : "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text(isConnected ? "Womit kann ich helfen?" : "Verbinde dein ChatGPT-Konto")
                .font(.title3.weight(.semibold))
            Text(!isConnected
                 ? "Melde dich in den Einstellungen mit deinem Codex-fähigen ChatGPT-Konto an."
                 : (selectedModel ? "Deine Unterhaltungen werden lokal auf diesem Gerät gespeichert." : "Wähle in den Einstellungen ein Modell oder füge eine Modell-ID hinzu."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

struct NoticeBanner: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
    }
}

struct ModelReasoningMenu: View {
    @ObservedObject var store: ChatStore
    @Binding var showingSettings: Bool

    private var selectedModel: ModelDefinition? {
        store.visibleModels.first { $0.id == store.state.preferences.selectedModelID }
    }

    private var reasoningLevels: [String] {
        let levels = selectedModel?.supportedReasoningLevels ?? []
        return levels.isEmpty ? ["low", "medium", "high"] : levels
    }

    var body: some View {
        Menu {
            Section("Modell") {
                if store.visibleModels.isEmpty {
                    Button("Modelle verwalten") { showingSettings = true }
                } else {
                    ForEach(store.visibleModels) { model in
                        Button {
                            store.selectModel(id: model.id)
                        } label: {
                            if model.id == store.state.preferences.selectedModelID {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                    Button("Modelleinstellungen …") { showingSettings = true }
                }
            }
            Section("Reasoning") {
                Button("Automatisch") { store.setReasoningLevel(nil) }
                ForEach(reasoningLevels, id: \.self) { level in
                    Button(level.capitalized) { store.setReasoningLevel(level) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.selectedModelName).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .frame(maxWidth: 220)
        }
        .accessibilityLabel("Modell und Reasoning auswählen")
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let canRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .padding(.top, 1)
            } else {
                Spacer(minLength: 36)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(message.text.isEmpty && message.status == .streaming ? " " : message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        if message.text.isEmpty && message.status == .streaming { ProgressView().controlSize(.small) }
                    }

                if let failure = message.failureMessage {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if canRetry {
                    Button(action: onRetry) {
                        Label("Erneut versuchen", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(message.role == .user ? 12 : 0)
            .background {
                if message.role == .user {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(maxWidth: 650, alignment: .leading)

            if message.role == .user { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

struct ComposerBar: View {
    @Binding var text: String
    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onAttachment: () -> Void
    let onVoice: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onAttachment) {
                Image(systemName: "plus")
                    .font(.title3)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Anhang hinzufügen")

            TextField("Nachricht schreiben", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .padding(.vertical, 9)
                .submitLabel(.send)
                .onSubmit { if canSend && !isGenerating { onSend() } }

            if isGenerating {
                Button(action: onCancel) {
                    Image(systemName: "stop.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.primary, in: Circle())
                        .foregroundStyle(Color(uiColor: .systemBackground))
                }
                .accessibilityLabel("Antwort stoppen")
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: onVoice) {
                    Image(systemName: "mic")
                        .font(.title3)
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("Spracheingabe")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .frame(width: 38, height: 38)
                        .background(canSend ? Color.primary : Color.secondary.opacity(0.35), in: Circle())
                        .foregroundStyle(Color(uiColor: .systemBackground))
                }
                .disabled(!canSend)
                .accessibilityLabel("Senden")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Verlauf, Einstellungen und Gerätecode

struct HistoryView: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.state.conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("Noch keine Chats").font(.headline)
                        Text("Starte einen neuen Chat, um ihn hier zu sehen.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.state.conversations) { conversation in
                            Button {
                                store.selectConversation(id: conversation.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title.isEmpty ? "Neuer Chat" : conversation.title)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                            .swipeActions {
                                Button(role: .destructive) { store.deleteConversation(id: conversation.id) } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Chatverlauf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.createConversation()
                        dismiss()
                    } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Neuer Chat")
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var session: CodexSessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var manualModelID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("ChatGPT / Codex") {
                    authSummary
                    if session.isConnected {
                        Button("Modellliste aktualisieren") { store.refreshModelCatalog() }
                        Button("Abmelden", role: .destructive) { session.signOut() }
                    } else {
                        Button {
                            session.startLogin()
                        } label: {
                            if session.state == .requestingCode {
                                HStack { ProgressView(); Text("Anmeldung wird vorbereitet …") }
                            } else {
                                Label("Mit ChatGPT anmelden", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        .disabled(session.state == .requestingCode || session.state == .waitingForApproval)
                    }
                    if let error = session.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Modell") {
                    if store.visibleModels.isEmpty {
                        Text("Nach der Anmeldung werden verfügbare Codex-Modelle geladen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.visibleModels) { model in
                        Button { store.selectModel(id: model.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.name).foregroundStyle(.primary)
                                    if model.origin == .manual {
                                        Text("Manuell hinzugefügt")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if store.state.preferences.selectedModelID == model.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("Eigene Modell-ID", text: $manualModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Hinzufügen") {
                            store.addManualModel(id: manualModelID)
                            manualModelID = ""
                        }
                        .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Reasoning") {
                    let levels = selectedReasoningLevels
                    if levels.isEmpty {
                        Text("Das ausgewählte Modell meldet keine Reasoning-Stufen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Stufe", selection: Binding(
                            get: { store.state.preferences.reasoningLevel ?? "auto" },
                            set: { store.setReasoningLevel($0 == "auto" ? nil : $0) }
                        )) {
                            Text("Automatisch").tag("auto")
                            ForEach(levels, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                }

                Section("Lokale Daten") {
                    Text("Chats und Einstellungen werden als JSON in den App-Daten gespeichert. OAuth-Tokens liegen getrennt im iOS-Schlüsselbund.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = store.persistenceError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section {
                    Text("Die Codex-Backend-Schnittstelle ist nicht als öffentliche API dokumentiert und kann sich ändern.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private var authSummary: some View {
        switch session.state {
        case .connected:
            Label(session.account?.displayName ?? "Verbunden", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let plan = session.account?.planName {
                Text(plan.capitalized).font(.footnote).foregroundStyle(.secondary)
            }
        case .waitingForApproval:
            Label("Warte auf Bestätigung im Browser", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .refreshing:
            HStack { ProgressView(); Text("Anmeldung wird erneuert …") }
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        case .requestingCode:
            Label("Anmeldung wird vorbereitet …", systemImage: "ellipsis")
                .foregroundStyle(.secondary)
        case .signedOut:
            Text("Nicht verbunden").foregroundStyle(.secondary)
        }
    }

    private var selectedReasoningLevels: [String] {
        guard let id = store.state.preferences.selectedModelID,
              let model = store.state.models.first(where: { $0.id == id }) else { return [] }
        return model.supportedReasoningLevels
    }
}

struct DeviceCodeSheet: View {
    let challenge: DeviceLoginChallenge
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            Text("Mit ChatGPT verbinden")
                .font(.title3.weight(.semibold))
            Text("Öffne die Anmeldeseite und gib diesen einmaligen Code ein.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(challenge.userCode)
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .textSelection(.enabled)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            Link(destination: challenge.verificationURL) {
                Label("Anmeldeseite öffnen", systemImage: "arrow.up.right.square")
                    .font(.body.weight(.semibold))
            }
            Text("Der Code läuft in 15 Minuten ab.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Abbrechen", role: .cancel) {
                cancel()
                dismiss()
            }
            .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// SwiftUI-App-Einstiegspunkt. In einem Xcode-Projekt eine eventuell vorhandene
// @main-Vorlage durch diesen Einstieg ersetzen, damit es genau einen App-Typ gibt.
@main
struct SwiftChatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
