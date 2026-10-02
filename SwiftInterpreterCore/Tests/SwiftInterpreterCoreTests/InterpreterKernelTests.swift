import Foundation
import XCTest
@testable import SwiftInterpreterCore

final class InterpreterKernelTests: XCTestCase {
    func testEvaluatesSwiftExpression() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate("1 + 2 * 3")

        XCTAssertEqual(result.value, "7")
    }

    func testResetStartsANewInterpreterSession() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let value = 7")
        let valueInCurrentSession = try await kernel.evaluate("value")
        XCTAssertEqual(valueInCurrentSession.value, "7")

        await kernel.reset()

        // A fresh interpreter must not retain declarations from the old run.
        do {
            _ = try await kernel.evaluate("value")
            XCTFail("Expected the reset interpreter to have an empty scope")
        } catch {
            // An unresolved-name diagnostic is the expected result.
        }
    }

    func testProjectSessionsDoNotShareDeclarations() async throws {
        let first = InterpreterKernel(workspace: try makeWorkspace())
        let second = InterpreterKernel(workspace: try makeWorkspace())

        _ = try await first.evaluate("let projectValue = 11")
        let value = try await first.evaluate("projectValue")
        XCTAssertEqual(value.value, "11")

        do {
            _ = try await second.evaluate("projectValue")
            XCTFail("A project must not see another project's interpreter scope")
        } catch {
            // An unresolved-name diagnostic is expected in the second project.
        }
    }

    func testCapturesPrintedOutput() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate("print(\"hello from project\")")

        XCTAssertEqual(result.standardOutput, "hello from project\n")
    }

    func testEvaluatesSwiftChatModelDeclarationsAndCodablePersistence() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = #"""
        import Foundation

        enum ChatRole: String, Codable, Equatable { case user, assistant }
        enum MessageStatus: String, Codable, Equatable {
            case completed, streaming, interrupted, failed, cancelled
        }
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

        extension ChatConversation {
            var messageCount: Int { messages.count }
        }

        let now = Date()
        let conversationID = UUID()
        let messageID = UUID()
        let model = ModelDefinition(
            id: "gpt-5",
            name: "GPT-5",
            origin: .manual,
            availability: .available,
            supportedReasoningLevels: ["low", "high"]
        )
        let message = ChatMessage(
            id: messageID,
            role: .user,
            text: "Hello",
            createdAt: now,
            status: .completed,
            requestID: UUID(),
            generationID: UUID(),
            modelID: model.id,
            reasoningLevel: nil,
            retryOfMessageID: nil,
            failureMessage: nil
        )
        let conversation = ChatConversation(
            id: conversationID,
            title: "Conversation",
            createdAt: now,
            updatedAt: now,
            modelID: model.id,
            reasoningLevel: nil,
            messages: [message]
        )
        let index = ChatIndex(
            conversationIDs: [conversationID],
            activeConversationID: conversationID,
            preferences: ChatPreferences(
                selectedModelID: model.id,
                reasoningLevel: nil,
                visibleModelIDs: [model.id]
            ),
            models: [model]
        )

        let conversationData = try JSONEncoder().encode(conversation)
        let restoredConversation = try JSONDecoder().decode(ChatConversation.self, from: conversationData)
        let indexData = try JSONEncoder().encode(index)
        let restoredIndex = try JSONDecoder().decode(ChatIndex.self, from: indexData)
        let restoredModelMatches = restoredIndex.models[0] == model
        let identifiersMatch = restoredConversation.id == conversationID
            && restoredConversation.messages[0].id == messageID
        let defaultsAreEmpty = ChatIndex().conversationIDs.count == 0
            && ChatPreferences().visibleModelIDs.count == 0

        "\(restoredConversation.title)|\(restoredConversation.messageCount)|\(restoredConversation.messages[0].role.rawValue)|\(restoredConversation.messages[0].modelID ?? "none")|\(identifiersMatch)|\(restoredModelMatches)|\(defaultsAreEmpty)"
        """#

        let result = try await kernel.evaluate(source)

        XCTAssertEqual(result.value, "Conversation|1|user|gpt-5|true|true|true")
    }

    func testEvaluatesClassProtocolDispatchAndExtensionConformance() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        protocol SecureCredentialStore {
            func readCredentials() -> String
        }

        protocol LabelProviding {
            var label: String { get }
        }

        final class MemoryCredentialStore: SecureCredentialStore {
            private let token: String

            init(token: String) { self.token = token }
            func readCredentials() -> String { token }
        }

        extension MemoryCredentialStore {
            var label: String { "memory:" + token }
        }

        extension MemoryCredentialStore: LabelProviding {}

        let concreteStore = MemoryCredentialStore(token: "secret")
        let store: SecureCredentialStore = concreteStore
        let labelledStore: LabelProviding = concreteStore
        store.readCredentials() + "|" + labelledStore.label
        """

        let result = try await kernel.evaluate(source)

        XCTAssertEqual(result.value, "secret|memory:secret")
    }

    func testEvaluatesAssociatedValueEnums() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate(
            #"""
            enum ChatProviderEvent { case textDelta(String) }
            enum CodexAuthState: Equatable {
                case signedOut, requestingCode, waitingForApproval, connected, refreshing
                case failed(String)
            }
            let event = ChatProviderEvent.textDelta("delta")
            var receivedText = ""
            switch event {
            case .textDelta(let text): receivedText = text
            }
            let failedState = CodexAuthState.failed("expired")
            "\(receivedText)|\(failedState == .failed("expired"))"
            """#
        )

        XCTAssertEqual(result.value, "delta|true")
    }

    func testEvaluatesResultAndThrownErrorPaths() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = #"""
        import Foundation

        enum AuthFailure: Error {
            case unauthorized
            case transport(String)
        }

        extension AuthFailure: LocalizedError {
            var errorDescription: String? {
                switch self {
                case .unauthorized: return "Not authorized"
                case .transport(let message): return message
                }
            }
        }

        func token(_ shouldFail: Bool) throws -> String {
            if shouldFail { throw AuthFailure.transport("offline") }
            return "token"
        }

        func describe(_ result: Result<String, AuthFailure>) -> String {
            switch result {
            case .success(let value): return value
            case .failure(.unauthorized): return "unauthorized"
            case .failure(.transport(let message)): return message
            }
        }

        let success = describe(.success("ready"))
        let failure = describe(.failure(.unauthorized))
        var caughtMessage = ""
        do {
            _ = try token(true)
        } catch {
            caughtMessage = error.localizedDescription
        }
        let optionalFailure = try? token(true)
        let optionalSuccess = try? token(false)
        let localizedMessage = AuthFailure.unauthorized.errorDescription ?? "missing"

        "\(success)|\(failure)|\(caughtMessage)|\(optionalFailure == nil)|\(optionalSuccess ?? "none")|\(localizedMessage)"
        """#

        let result = try await kernel.evaluate(source)

        XCTAssertEqual(result.value, "ready|unauthorized|offline|true|token|Not authorized")
    }

    func testEvaluatesInoutMutation() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate(
            #"""
            func writeResult(_ output: inout String?, value: String?) {
                output = value
            }
            var result: String? = nil
            writeResult(&result, value: "matched")
            let writtenValue = result ?? "missing"
            writeResult(&result, value: nil)
            "\(writtenValue)|\(result == nil)"
            """#
        )

        XCTAssertEqual(result.value, "matched|true")
    }

    func testEvaluatesTargetKeyPathForms() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate(
            #"""
            struct ModelDefinition {
                var id: String
                var supportedReasoningLevels: [String]
            }
            let models = [
                ModelDefinition(id: "first", supportedReasoningLevels: ["low"]),
                ModelDefinition(id: "second", supportedReasoningLevels: ["low", "high"])
            ]
            let modelIDs = models.map(\.id).joined(separator: ",")
            let levels = ["low", "high"].map(\.self).joined(separator: ",")
            modelIDs + "|" + levels
            """#
        )

        XCTAssertEqual(result.value, "first,second|low,high")
    }

    func testEvaluatesEscapingClosuresAndWeakSelfCapture() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = #"""
        func register(_ callback: @escaping (String) -> String) -> (String) -> String {
            callback
        }

        final class CallbackOwner {
            let value: String

            init(value: String) { self.value = value }

            func makeReader() -> () -> String {
                { [weak self] in
                    guard let self = self else { return "released" }
                    return self.value
                }
            }
        }

        let registered = register { value in "callback:" + value }
        var owner: CallbackOwner? = CallbackOwner(value: "alive")
        let reader = owner!.makeReader()
        let valueWhileAlive = reader()
        owner = nil
        let valueAfterRelease = reader()
        "\(valueWhileAlive)|\(registered(valueAfterRelease))"
        """#

        let result = try await kernel.evaluate(source)

        XCTAssertEqual(result.value, "alive|callback:released")
    }

    func testEvaluatesRemainingSwiftChatCastTupleAndControlFlowPatterns() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = #"""
        func accountFields(_ claims: [String: Any]) -> (id: String?, name: String?) {
            let auth = claims["auth"] as? [String: Any] ?? [:]
            let accountID = (auth["account_id"] as? String) ?? (claims["account_id"] as? String)
            let name = (claims["name"] as? String) ?? (claims["email"] as? String)
            return (accountID, name)
        }

        func modelNames(from rows: [[String: Any]]) -> [String] {
            rows.compactMap { row in
                let apiSupported = row["supported_in_api"] as? Bool ?? true
                guard apiSupported,
                      let id = (row["slug"] as? String) ?? (row["id"] as? String),
                      !id.isEmpty else { return nil }
                let name = (row["display_name"] as? String) ?? (row["name"] as? String) ?? id
                return id + ":" + name
            }
        }

        func paddedBase64Segment(_ segment: String) -> String {
            var padded = segment
            while padded.count % 4 != 0 { padded.append("=") }
            return padded
        }

        func consumeLines(_ lines: [String]) -> String {
            var pending = lines
            var consumed = ""
            while let line = pending.first {
                if !consumed.isEmpty { consumed += "," }
                consumed += line
                pending.removeFirst()
            }
            return consumed
        }

        var lockTrace = ""
        func withLock() -> String {
            defer { lockTrace += ":unlock" }
            lockTrace = "locked"
            return lockTrace
        }

        let fields = accountFields([
            "auth": ["account_id": "acct-1"],
            "name": "Ada"
        ])
        let models = modelNames(from: [
            ["slug": "gpt-5", "display_name": "GPT-5", "supported_in_api": true],
            ["id": "", "name": "empty", "supported_in_api": true],
            ["id": "preview", "name": "Preview", "supported_in_api": false],
            ["id": 42, "supported_in_api": true]
        ])
        var modelList = ""
        for model in models where !model.isEmpty {
            if !modelList.isEmpty { modelList += "," }
            modelList += model
        }
        let lockValue = withLock()
        enum SessionState { case signedOut, connected }
        let state: SessionState = .connected
        var stateLabel = "signed out"
        if case .connected = state { stateLabel = "connected" }
        enum StreamError: Error { case interrupted }
        let completion: Result<Void, StreamError> = .success(())
        var completionLabel = "failed"
        switch completion {
        case .success: completionLabel = "completed"
        case .failure: completionLabel = "failed"
        }

        "\(fields.id ?? "missing")|\(fields.name ?? "missing")|\(modelList)|\(paddedBase64Segment("ab"))|\(consumeLines(["event", "[DONE]"]))|\(lockValue)|\(lockTrace)|\(stateLabel)|\(completionLabel)"
        """#

        let result = try await kernel.evaluate(source)

        XCTAssertEqual(result.value, "acct-1|Ada|gpt-5:GPT-5|ab==|event,[DONE]|locked|locked:unlock|connected|completed")
    }

    func testPreflightReturnsRuntimeDiagnosticsBeforeEvaluation() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())

        do {
            _ = try await kernel.evaluate("import SwiftUI\nstruct Demo: View {}")
            XCTFail("SwiftUI evaluation must wait for its runtime bridge")
        } catch let error as SourcePreflightError {
            XCTAssertEqual(error.analysis.importedModules, ["SwiftUI"])
            XCTAssertTrue(error.analysis.diagnostics.contains { $0.code == .moduleCustomRuntimeRequired })
        }
    }

    func testKernelResolvesTheInterpretedAppRootView() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct ContentView: View { var body: some View { Text("Chat") } }
        @main struct SwiftChatApp: App {
            var body: some Scene { WindowGroup { ContentView() } }
        }
        """

        let entryPoint = try await kernel.resolveAppEntryPoint(in: source)

        XCTAssertEqual(entryPoint.appTypeName, "SwiftChatApp")
        XCTAssertEqual(entryPoint.rootViewTypeName, "ContentView")
    }

    func testLowerViewExpressionResolvesDynamicTextFromCurrentInterpreterScope() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var caption = \"first\"")

        let first = try await kernel.lowerViewExpression("VStack { Text(caption) }")
        XCTAssertEqual(
            first,
            .verticalStack(alignment: .center, spacing: nil, children: [.text("first")])
        )

        _ = try await kernel.evaluate("caption = \"second\"")
        let second = try await kernel.lowerViewExpression("VStack { Text(caption) }")
        XCTAssertEqual(
            second,
            .verticalStack(alignment: .center, spacing: nil, children: [.text("second")])
        )

        _ = try await kernel.evaluate("let displayName = \"Ada\"")
        let interpolated = try await kernel.lowerViewExpression(#"Text("Hallo \(displayName)")"#)
        XCTAssertEqual(interpolated, .text("Hallo Ada"))
    }

    func testLowerViewBodyExtractsTheNamedStructAndUsesInterpreterScope() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var bodyCaption = \"first\"")
        let source = """
        struct OtherView {
            var body: some View { Text("wrong type") }
        }
        struct SelectedView {
            var body: some View {
                VStack { Text(bodyCaption) }
            }
        }
        """

        let first = try await kernel.lowerViewBody(in: source, typeName: "SelectedView")
        XCTAssertEqual(
            first,
            .verticalStack(alignment: .center, spacing: nil, children: [.text("first")])
        )

        _ = try await kernel.evaluate("bodyCaption = \"updated\"")
        let updated = try await kernel.lowerViewBody(in: source, typeName: "SelectedView")
        XCTAssertEqual(
            updated,
            .verticalStack(alignment: .center, spacing: nil, children: [.text("updated")])
        )
    }

    func testLowerViewBodySupportsExplicitGetterReturnAndMultipleExpressions() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let returned = try await kernel.lowerViewBody(
            in: """
            struct ReturnedView {
                var body: some View {
                    get { return Text("returned") }
                }
            }
            """,
            typeName: "ReturnedView"
        )
        XCTAssertEqual(returned, .text("returned"))

        let grouped = try await kernel.lowerViewBody(
            in: """
            struct GroupedView {
                var body: some View {
                    Text("first")
                    Text("second")
                }
            }
            """,
            typeName: "GroupedView"
        )
        XCTAssertEqual(.group([.text("first"), .text("second")]), grouped)
    }

    func testLowerViewBodyExpandsNestedCustomViewsWithMemberwiseInputs() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct HostView: View {
            var body: some View {
                GreetingPanel(title: "Hello")
            }
        }

        struct GreetingPanel: View {
            let title: String

            var body: some View {
                VStack {
                    Text(title)
                    CaptionLabel(text: title)
                }
            }
        }

        struct CaptionLabel: View {
            let text: String

            var body: some View { Text(text) }
        }
        """

        let view = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        XCTAssertEqual(
            view,
            .verticalStack(
                alignment: .center,
                spacing: nil,
                children: [.text("Hello"), .text("Hello")]
            )
        )
    }

    func testCustomViewInputCanResolveAgainstStateInTheCurrentKernelScope() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct HostView: View {
            @State private var isActive = true

            var body: some View {
                StatusView(active: isActive)
            }
        }

        struct StatusView: View {
            let active: Bool

            var body: some View {
                if active { Text("Active") } else { Text("Paused") }
            }
        }
        """

        let active = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        XCTAssertEqual(active, .text("Active"))

        _ = try await kernel.evaluate("isActive = false")
        let paused = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        XCTAssertEqual(paused, .text("Paused"))
    }

    func testCustomViewTextInputRefreshesFromTheCurrentInterpreterScope() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var liveCaption = \"First\"")
        let source = """
        struct HostView: View {
            var body: some View { CaptionView(text: liveCaption) }
        }

        struct CaptionView: View {
            let text: String
            var body: some View { Text(text) }
        }
        """

        let first = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        XCTAssertEqual(first, .text("First"))

        _ = try await kernel.evaluate("liveCaption = \"Updated\"")
        let updated = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        XCTAssertEqual(updated, .text("Updated"))
    }

    func testCustomViewExpansionRejectsUnsupportedInitializersAndRecursion() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let invalidSources = [
            (
                """
                struct HostView: View { var body: some View { MutableLabel(text: "x") } }
                struct MutableLabel: View {
                    var text: String
                    var body: some View { Text(text) }
                }
                """,
                "HostView"
            ),
            (
                """
                struct HostView: View { var body: some View { LabelView() } }
                struct LabelView: View {
                    let text: String
                    var body: some View { Text(text) }
                }
                """,
                "HostView"
            ),
            (
                "struct RecursiveView: View { var body: some View { RecursiveView() } }",
                "RecursiveView"
            )
        ]

        for (source, typeName) in invalidSources {
            do {
                _ = try await kernel.lowerViewBody(in: source, typeName: typeName)
                XCTFail("Expected unsupported custom-view composition to be rejected")
            } catch let error as RuntimeViewLoweringError {
                guard isCustomViewDiagnostic(error) else {
                    return XCTFail("Expected a custom-view lowering diagnostic, got \(error)")
                }
            }
        }
    }

    private func isCustomViewDiagnostic(_ error: RuntimeViewLoweringError) -> Bool {
        if case .unsupportedExpression = error { return true }
        if case .unsupportedArgument = error { return true }
        return false
    }

    func testLowerViewBodyRejectsMissingOrStoredBodyProperties() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())

        for (source, typeName) in [
            ("struct MissingView {}", "MissingView"),
            ("struct StoredView { var body: String = \"not computed\" }", "StoredView"),
            ("struct ExistingView { var body: some View { Text(\"x\") } }", "AbsentView")
        ] {
            do {
                _ = try await kernel.lowerViewBody(in: source, typeName: typeName)
                XCTFail("Expected body extraction to reject \(typeName)")
            } catch let error as RuntimeViewLoweringError {
                guard case .unsupportedExpression = error else {
                    return XCTFail("Expected a body extraction diagnostic")
                }
            }
        }
    }

    func testLowerViewBodySeedsStateLiteralsOnceAndResetRestoresTheirInitialValues() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct StateView {
            @State private var isVisible = true
            @State private var caption = "Initial"

            var body: some View {
                if isVisible {
                    Text(caption)
                } else {
                    Text("Hidden")
                }
            }
        }
        """

        let initial = try await kernel.lowerViewBody(in: source, typeName: "StateView")
        XCTAssertEqual(initial, .text("Initial"))

        _ = try await kernel.evaluate("caption = \"Changed\"")
        let changed = try await kernel.lowerViewBody(in: source, typeName: "StateView")
        XCTAssertEqual(changed, .text("Changed"))

        _ = try await kernel.evaluate("isVisible = false")
        let hidden = try await kernel.lowerViewBody(in: source, typeName: "StateView")
        XCTAssertEqual(hidden, .text("Hidden"))

        await kernel.reset()
        let reset = try await kernel.lowerViewBody(in: source, typeName: "StateView")
        XCTAssertEqual(reset, .text("Initial"))
    }

    func testLowerViewBodyRejectsNonLiteralStateInitializers() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct DynamicStateView {
            @State private var caption = makeCaption()
            var body: some View { Text(caption) }
        }
        """

        do {
            _ = try await kernel.lowerViewBody(in: source, typeName: "DynamicStateView")
            XCTFail("Expected a non-literal State initializer to be rejected")
        } catch let error as RuntimeViewLoweringError {
            guard case .unsupportedExpression(let detail) = error else {
                return XCTFail("Expected a state initializer diagnostic")
            }
            XCTAssertTrue(detail.contains("plain String or Bool literal"))
        }
    }

    func testLowerViewBodyRejectsStateNameCollisionsAcrossViewTypes() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let firstSource = """
        struct FirstStateView {
            @State private var isVisible = true
            var body: some View {
                if isVisible { Text("First") } else { Text("Hidden") }
            }
        }
        """
        let secondSource = """
        struct SecondStateView {
            @State private var isVisible = false
            var body: some View {
                if isVisible { Text("Second") } else { Text("Hidden") }
            }
        }
        """

        let first = try await kernel.lowerViewBody(in: firstSource, typeName: "FirstStateView")
        XCTAssertEqual(first, .text("First"))

        do {
            _ = try await kernel.lowerViewBody(in: secondSource, typeName: "SecondStateView")
            XCTFail("Expected same-named State properties to require separate view state")
        } catch let error as RuntimeViewLoweringError {
            guard case .unsupportedExpression(let detail) = error else {
                return XCTFail("Expected a state scope diagnostic")
            }
            XCTAssertTrue(detail.contains("already initialized for FirstStateView"))
        }
    }

    func testDynamicConditionResolvesOnlyTheSelectedBranchAndItsText() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var shouldShow = true")
        _ = try await kernel.evaluate("let activeCaption = \"Visible from scope\"")

        let source = "VStack { if shouldShow { Text(activeCaption) } else { Text(missingCaption) } }"
        let shown = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(
            shown,
            .verticalStack(alignment: .center, spacing: nil, children: [.text("Visible from scope")])
        )

        _ = try await kernel.evaluate("shouldShow = false")
        let hidden = try await kernel.lowerViewExpression(
            "VStack { if shouldShow { Text(activeCaption) } else { Text(\"Hidden branch\") } }"
        )
        XCTAssertEqual(
            hidden,
            .verticalStack(alignment: .center, spacing: nil, children: [.text("Hidden branch")])
        )

        let omitted = try await kernel.lowerViewExpression("if shouldShow { Text(missingCaption) }")
        XCTAssertEqual(omitted, .empty)
    }

    func testNestedDynamicConditionsOnlyResolveReachableBranches() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var showOuter = true")
        _ = try await kernel.evaluate("var showInner = false")

        let view = try await kernel.lowerViewExpression("""
        VStack {
            if showOuter {
                if showInner {
                    Text(unavailableInnerText)
                } else {
                    Text("Selected nested branch")
                }
            } else {
                Text(unavailableOuterText)
            }
        }
        """)

        XCTAssertEqual(
            view,
            .verticalStack(alignment: .center, spacing: nil, children: [.text("Selected nested branch")])
        )

        _ = try await kernel.evaluate("showOuter = false")
        let outerFallback = try await kernel.lowerViewExpression("""
        VStack {
            if showOuter {
                if unavailableInnerCondition {
                    Text("unreachable")
                }
            } else {
                Text("Outer fallback")
            }
        }
        """)
        XCTAssertEqual(
            outerFallback,
            .verticalStack(alignment: .center, spacing: nil, children: [.text("Outer fallback")])
        )
    }

    func testDynamicElseIfConditionsAreResolvedInOrder() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let firstChoice = false")
        _ = try await kernel.evaluate("let secondChoice = true")

        let view = try await kernel.lowerViewExpression(
            "if firstChoice { Text(unavailableFirstText) } else if secondChoice { Text(\"Second choice\") } else { Text(\"Fallback\") }"
        )

        XCTAssertEqual(view, .text("Second choice"))
    }

    func testOptionalBindingSelectsBranchAndProvidesBoundTextValue() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var pendingCaption: String? = \"Waiting\"")

        let source = "if let caption = pendingCaption { Text(caption) } else { Text(\"No caption\") }"
        let waiting = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(waiting, .text("Waiting"))

        _ = try await kernel.evaluate("pendingCaption = nil")
        let empty = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(empty, .text("No caption"))

        _ = try await kernel.evaluate("pendingCaption = \"Ready\"")
        let ready = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(ready, .text("Ready"))
    }

    func testOptionalBindingSupportsFollowingBooleanConditions() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var optionalCount: Int? = 3")

        let source = "if let count = optionalCount, count > 2 { Text(count) } else { Text(\"Hidden\") }"
        let visible = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(visible, .text("3"))

        _ = try await kernel.evaluate("optionalCount = 1")
        let hidden = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(hidden, .text("Hidden"))
    }

    func testNilOptionalBindingDoesNotEvaluateItsInactiveBranch() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let optionalCaption: String? = nil")

        let view = try await kernel.lowerViewExpression(
            "if let caption = optionalCaption { Text(unavailableCaption) } else { Text(\"No caption\") }"
        )

        XCTAssertEqual(view, .text("No caption"))
    }

    func testOptionalBindingScopeDoesNotLeakAcrossSiblingBranches() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let firstOptionalName: String? = \"First\"")
        _ = try await kernel.evaluate("let secondOptionalName: String? = \"Second\"")

        let view = try await kernel.lowerViewExpression("""
        VStack {
            if let name = firstOptionalName { Text(name) }
            if let name = secondOptionalName { Text(name) }
        }
        """)

        XCTAssertEqual(
            view,
            .verticalStack(alignment: .center, spacing: nil, children: [.text("First"), .text("Second")])
        )
    }

    func testBoundOptionalValueCanDriveDisabledModifier() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let optionalCanSend: Bool? = true")

        let view = try await kernel.lowerViewExpression(
            "if let canSend = optionalCanSend { Text(\"Send\").disabled(!canSend) }"
        )

        XCTAssertEqual(
            view,
            .modified(content: .text("Send"), modifier: .disabled(false))
        )
    }

    func testDynamicConditionStillPreflightsUnsupportedInactiveBranch() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let showSupportedBranch = true")

        do {
            _ = try await kernel.lowerViewExpression(
                "if showSupportedBranch { Text(\"shown\") } else { Menu { Text(\"unsupported\") } }"
            )
            XCTFail("An unsupported view must be rejected even in an inactive branch")
        } catch let error as RuntimeViewLoweringError {
            XCTAssertEqual(error, .unsupportedView("Menu"))
        }
    }

    func testButtonActionRunsInTheExistingStateAndClearsOnReset() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var tapCount = 0")
        let source = """
        struct ActionView: View {
            @State private var isActive = false

            var body: some View {
                VStack {
                    if isActive { Text("Active") } else { Text("Inactive") }
                    Button("Toggle", role: .cancel) {
                        if isActive { tapCount = tapCount + 1 }
                        isActive = !isActive
                        print("tapped")
                    }
                }
            }
        }
        """

        let initial = try await kernel.lowerViewBody(in: source, typeName: "ActionView")
        guard case .verticalStack(_, _, let initialChildren) = initial,
              initialChildren.count == 2,
              case .button(_, let firstActionID, let role) = initialChildren[1] else {
            return XCTFail("Expected the initial view to contain the Toggle button")
        }
        XCTAssertEqual(initialChildren[0], .text("Inactive"))
        XCTAssertEqual(role, .cancel)

        let firstActionResult = try await kernel.performAction(firstActionID)
        XCTAssertEqual(firstActionResult.standardOutput, "tapped\n")

        let active = try await kernel.lowerViewBody(in: source, typeName: "ActionView")
        guard case .verticalStack(_, _, let activeChildren) = active,
              activeChildren.count == 2,
              case .button(_, let secondActionID, _) = activeChildren[1] else {
            return XCTFail("Expected the updated view to retain the Toggle button")
        }
        XCTAssertEqual(activeChildren[0], .text("Active"))

        do {
            _ = try await kernel.performAction(firstActionID)
            XCTFail("A new lowered tree must replace the preceding action table")
        } catch let error as RuntimeActionError {
            XCTAssertEqual(error, .unknownAction(firstActionID))
        }

        _ = try await kernel.performAction(secondActionID)
        let finalActiveState = try await kernel.evaluate("isActive")
        let updatedTapCount = try await kernel.evaluate("tapCount")
        XCTAssertEqual(finalActiveState.value, "false")
        XCTAssertEqual(updatedTapCount.value, "1")

        await kernel.reset()
        do {
            _ = try await kernel.performAction(secondActionID)
            XCTFail("Reset must remove registered button actions")
        } catch let error as RuntimeActionError {
            XCTAssertEqual(error, .unknownAction(secondActionID))
        }
    }

    func testDynamicConditionMustEvaluateToBoolean() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let itemCount = 3")

        do {
            _ = try await kernel.lowerViewExpression("if itemCount { Text(\"yes\") } else { Text(\"no\") }")
            XCTFail("A non-Boolean condition must be rejected")
        } catch let error as RuntimeViewLoweringError {
            guard case .unsupportedExpression(let detail) = error else {
                return XCTFail("Expected a Boolean-condition diagnostic")
            }
            XCTAssertTrue(detail.contains("conditional expression is not Bool"))
        }
    }

    func testDynamicDisabledModifierTracksCurrentInterpreterScope() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var canSend = false")

        let disabled = try await kernel.lowerViewExpression("Text(\"Send\").disabled(!canSend)")
        XCTAssertEqual(
            disabled,
            .modified(content: .text("Send"), modifier: .disabled(true))
        )

        _ = try await kernel.evaluate("canSend = true")
        let enabled = try await kernel.lowerViewExpression("Text(\"Send\").disabled(!canSend)")
        XCTAssertEqual(
            enabled,
            .modified(content: .text("Send"), modifier: .disabled(false))
        )
    }

    func testDynamicDisabledModifierInInactiveBranchIsNotEvaluated() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let showDisabledAction = false")

        let view = try await kernel.lowerViewExpression(
            "if showDisabledAction { Text(\"Hidden\").disabled(missingModifierValue) } else { Text(\"Visible\") }"
        )

        XCTAssertEqual(view, .text("Visible"))
    }

    func testDynamicDisabledModifierMustEvaluateToBoolean() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let disabledCount = 3")

        do {
            _ = try await kernel.lowerViewExpression("Text(\"Send\").disabled(disabledCount)")
            XCTFail("A non-Boolean disabled argument must be rejected")
        } catch let error as RuntimeViewLoweringError {
            guard case .unsupportedExpression(let detail) = error else {
                return XCTFail("Expected a Boolean modifier diagnostic")
            }
            XCTAssertTrue(detail.contains("disabled argument is not Bool"))
        }
    }

    func testReloadAndRunReadsUpdatedFileAndStartsFreshScope() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftInterpreterReloadTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let sourceURL = temporaryRoot.appendingPathComponent("LiveProject.swift")
        try Data("let liveValue = 20\nliveValue".utf8).write(to: sourceURL)

        let workspaceRoot = temporaryRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let projectID = ProjectID()
        let workspace = try ProjectWorkspaceStore(rootURL: workspaceRoot).workspace(for: projectID)
        let kernel = InterpreterKernel(workspace: workspace)

        let link = try await kernel.linkSourceFile(at: sourceURL)
        XCTAssertEqual(link.fileName, "LiveProject.swift")

        let firstRun = try await kernel.reloadAndRun()
        XCTAssertEqual(firstRun.value, "20")

        let stateViewSource = """
        struct ReloadStateView {
            @State private var isVisible = true
            var body: some View {
                if isVisible { Text("Visible") } else { Text("Hidden") }
            }
        }
        """
        let initialStateBody = try await kernel.lowerViewBody(
            in: stateViewSource,
            typeName: "ReloadStateView"
        )
        XCTAssertEqual(initialStateBody, .text("Visible"))
        _ = try await kernel.evaluate("isVisible = false")

        try Data("let liveValue = 42\nliveValue".utf8).write(to: sourceURL, options: .atomic)
        let secondRun = try await kernel.reloadAndRun()
        XCTAssertEqual(secondRun.value, "42")
        let reloadedStateBody = try await kernel.lowerViewBody(
            in: stateViewSource,
            typeName: "ReloadStateView"
        )
        XCTAssertEqual(reloadedStateBody, .text("Visible"))

        let reopenedWorkspace = try ProjectWorkspaceStore(rootURL: workspaceRoot).workspace(for: projectID)
        let reopenedKernel = InterpreterKernel(workspace: reopenedWorkspace)
        let persistedLink = try await reopenedKernel.linkedSourceFile()
        XCTAssertEqual(persistedLink?.fileName, "LiveProject.swift")
        let reopenedRun = try await reopenedKernel.reloadAndRun()
        XCTAssertEqual(reopenedRun.value, "42")

        try await reopenedKernel.unlinkSourceFile()
        let linkAfterUnlink = try await kernel.linkedSourceFile()
        XCTAssertNil(linkAfterUnlink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testReloadAndRunAppRendersRootAndRefreshesInTheSameSession() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftInterpreterAppReloadTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let sourceURL = temporaryRoot.appendingPathComponent("PreviewApp.swift")
        let workspaceRoot = temporaryRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let workspace = try ProjectWorkspaceStore(rootURL: workspaceRoot).workspace(for: ProjectID())
        let kernel = InterpreterKernel(workspace: workspace)

        func appSource(title: String) -> String {
            """
            import SwiftUI

            @main struct PreviewApp: App {
                var body: some Scene { WindowGroup { PreviewView() } }
            }

            struct PreviewView: View {
                @State private var title = "\(title)"
                var body: some View {
                    VStack {
                        Text(title)
                        Button("Change") { title = "Changed" }
                    }
                }
            }
            """
        }

        try Data(appSource(title: "First").utf8).write(to: sourceURL)
        _ = try await kernel.linkSourceFile(at: sourceURL)
        let firstRun = try await kernel.reloadAndRunApp()
        XCTAssertEqual(firstRun.sourceFileName, "PreviewApp.swift")
        XCTAssertEqual(firstRun.entryPoint.appTypeName, "PreviewApp")
        XCTAssertEqual(firstRun.entryPoint.rootViewTypeName, "PreviewView")
        guard case .verticalStack(_, _, let firstChildren) = firstRun.rootView,
              firstChildren.count == 2,
              case .button(_, let firstActionID, _) = firstChildren[1] else {
            return XCTFail("Expected the loaded root view and its Change button")
        }
        XCTAssertEqual(firstChildren[0], .text("First"))

        try Data(appSource(title: "Second").utf8).write(to: sourceURL, options: .atomic)
        let secondRun = try await kernel.reloadAndRunApp()
        guard case .verticalStack(_, _, let secondChildren) = secondRun.rootView,
              secondChildren.count == 2,
              case .button(_, let secondActionID, _) = secondChildren[1] else {
            return XCTFail("Expected the reloaded root view and its Change button")
        }
        XCTAssertEqual(secondChildren[0], .text("Second"))

        do {
            _ = try await kernel.performAction(firstActionID)
            XCTFail("Reloading the app must invalidate actions from the prior view tree")
        } catch let error as RuntimeActionError {
            XCTAssertEqual(error, .unknownAction(firstActionID))
        }

        _ = try await kernel.performAction(secondActionID)
        let refreshed = try await kernel.refreshAppView(secondRun)
        guard case .verticalStack(_, _, let refreshedChildren) = refreshed.rootView else {
            return XCTFail("Expected the root view to refresh after the action")
        }
        XCTAssertEqual(refreshedChildren[0], .text("Changed"))
    }

    private func makeWorkspace() throws -> ProjectWorkspace {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftInterpreterCoreTests-\(UUID().uuidString)", isDirectory: true)
        let store = ProjectWorkspaceStore(rootURL: rootURL)
        return try store.workspace(for: ProjectID())
    }

}

final class ProjectWorkspaceTests: XCTestCase {
    func testWorkspaceIdentityReopensTheSameDirectoryAndSeparatesOtherProjects() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftInterpreterWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let store = ProjectWorkspaceStore(rootURL: baseURL)
        let id = ProjectID()
        let firstOpen = try store.workspace(for: id)
        let reopened = try store.workspace(for: id)
        let other = try store.workspace(for: ProjectID())

        XCTAssertEqual(firstOpen.rootURL, reopened.rootURL)
        XCTAssertNotEqual(firstOpen.rootURL, other.rootURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstOpen.rootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.rootURL.path))
    }
}
