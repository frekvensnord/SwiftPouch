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

    func testForEachLowersIdentifiableRowsWithStableIDsAndRefreshesFromCurrentData() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        struct Entry: Identifiable {
            let id: String
            let title: String
        }
        var entries = [Entry(id: "first", title: "Alpha"), Entry(id: "second", title: "Beta")]
        """)

        let source = "ForEach(entries) { entry in Text(entry.title) }"
        let first = try await kernel.lowerViewExpression(source)
        guard case .forEach(let firstItems) = first else {
            return XCTFail("Expected an identified ForEach node")
        }
        XCTAssertEqual(firstItems.map(\.id.rawValue), ["6:String5:first", "6:String6:second"])
        XCTAssertEqual(firstItems.map(\.content), [.text("Alpha"), .text("Beta")])

        _ = try await kernel.evaluate("entries.append(Entry(id: \"third\", title: \"Gamma\"))")
        let refreshed = try await kernel.lowerViewExpression(source)
        guard case .forEach(let refreshedItems) = refreshed else {
            return XCTFail("Expected the refreshed collection to remain a ForEach node")
        }
        XCTAssertEqual(refreshedItems.map(\.id), firstItems.map(\.id) + [RuntimeForEachID(rawValue: "6:String5:third")])
        XCTAssertEqual(refreshedItems.map(\.content), [.text("Alpha"), .text("Beta"), .text("Gamma")])

        _ = try await kernel.evaluate("entries = [entries[1], entries[0], entries[2]]")
        let reordered = try await kernel.lowerViewExpression(source)
        guard case .forEach(let reorderedItems) = reordered else {
            return XCTFail("Expected reordering to preserve the identified collection node")
        }
        XCTAssertEqual(reorderedItems.map(\.id), [refreshedItems[1].id, refreshedItems[0].id, refreshedItems[2].id])
        XCTAssertEqual(reorderedItems.map(\.content), [.text("Beta"), .text("Alpha"), .text("Gamma")])
    }

    func testForEachSupportsExplicitSelfIDsAndIntegerRanges() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let levels = [\"low\", \"high\"]")

        let strings = try await kernel.lowerViewExpression(
            #"ForEach(levels, id: \.self) { level in Text(level) }"#
        )
        guard case .forEach(let levelItems) = strings else {
            return XCTFail("Expected an explicit-ID ForEach node")
        }
        XCTAssertEqual(levelItems.map(\.content), [.text("low"), .text("high")])
        XCTAssertEqual(levelItems.map(\.id.rawValue), ["6:String3:low", "6:String4:high"])

        let numbers = try await kernel.lowerViewExpression(
            #"ForEach(2..<5, id: \.self) { index in Text(index) }"#
        )
        guard case .forEach(let numberItems) = numbers else {
            return XCTFail("Expected a range-backed ForEach node")
        }
        XCTAssertEqual(numberItems.map(\.content), [.text("2"), .text("3"), .text("4")])
    }

    func testForEachResolvesConditionsAndCapturesEachItemInActions() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        struct Entry: Identifiable {
            let id: String
            let title: String
            let isVisible: Bool
        }
        var selectedID = ""
        let entries = [
            Entry(id: "hidden", title: "Hidden", isVisible: false),
            Entry(id: "shown", title: "Shown", isVisible: true)
        ]
        """)

        let node = try await kernel.lowerViewExpression("""
        ForEach(entries) { entry in
            if entry.isVisible {
                Button("Choose") { selectedID = entry.id }
            } else {
                Text(entry.title)
            }
        }
        """)
        guard case .forEach(let items) = node,
              items.count == 2,
              case .text("Hidden") = items[0].content,
              case .button(_, let actionID, _) = items[1].content else {
            return XCTFail("Expected conditional content and a per-row action")
        }

        _ = try await kernel.performAction(actionID)
        let selected = try await kernel.evaluate("selectedID")
        XCTAssertEqual(selected.value, "shown")
    }

    func testForEachRejectsDuplicateIDsAndKeepsEmptyCollectionsEmpty() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        struct Entry { let id: String; let title: String }
        let duplicateEntries = [Entry(id: "same", title: "A"), Entry(id: "same", title: "B")]
        let noEntries: [String] = []
        """)

        do {
            _ = try await kernel.lowerViewExpression(
                "ForEach(duplicateEntries) { entry in Text(entry.title) }"
            )
            XCTFail("Duplicate identities must not produce ambiguous SwiftUI rows")
        } catch let error as RuntimeViewLoweringError {
            guard case .duplicateForEachIdentifier = error else {
                return XCTFail("Expected a duplicate-ID diagnostic, got: \(error)")
            }
        }

        let empty = try await kernel.lowerViewExpression(
            "ForEach(noEntries, id: \\.self) { entry in Text(entry) }"
        )
        XCTAssertEqual(empty, .forEach([]))
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

    func testCustomViewInputPreservesExpressionPrecedence() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct HostView: View {
            var body: some View { FlagView(flag: false || true) }
        }
        struct FlagView: View {
            let flag: Bool
            var body: some View {
                if !flag { Text("False") } else { Text("True") }
            }
        }
        """

        let view = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        XCTAssertEqual(view, .text("True"))
    }

    func testCustomViewLiteralInputRemainsStaticButtonTitle() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct HostView: View {
            var body: some View { ActionView(title: "Continue") }
        }
        struct ActionView: View {
            let title: String
            var body: some View { Button(title) { print("tapped") } }
        }
        """

        let view = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        guard case .button(let label, let actionID, _) = view else {
            return XCTFail("Expected a button with the substituted title")
        }
        XCTAssertEqual(label, .text("Continue"))
        let result = try await kernel.performAction(actionID)
        XCTAssertEqual(result.standardOutput, "tapped\n")
    }

    func testCustomViewBindingReadsAndWritesTheParentStateCell() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct HostView: View {
            @State private var isActive = true

            var body: some View {
                StatusView(active: $isActive)
            }
        }

        struct StatusView: View {
            @Binding var active: Bool

            var body: some View {
                VStack {
                    if active { Text("Active") } else { Text("Paused") }
                    Button("Pause") { active = false }
                }
            }
        }
        """

        let active = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        guard case .verticalStack(_, _, let activeChildren) = active,
              activeChildren.count == 2,
              case .button(_, let pauseActionID, _) = activeChildren[1] else {
            return XCTFail("Expected the binding-backed child and Pause button")
        }
        XCTAssertEqual(activeChildren[0], .text("Active"))

        _ = try await kernel.performAction(pauseActionID)
        let paused = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        guard case .verticalStack(_, _, let pausedChildren) = paused,
              pausedChildren.count == 2 else {
            return XCTFail("Expected the refreshed binding-backed child")
        }
        XCTAssertEqual(pausedChildren[0], .text("Paused"))
    }

    func testBindingProjectionForwardsThroughCustomViewsToTheSameStateCell() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct HostView: View {
            @State private var draft = "Initial"

            var body: some View {
                ForwardingView(text: $draft)
            }
        }

        struct ForwardingView: View {
            @Binding var text: String

            var body: some View {
                VStack {
                    Text(text)
                    EditingView(text: $text)
                    EditingView(text: self.$text)
                }
            }
        }

        struct EditingView: View {
            @Binding var text: String

            var body: some View {
                Button("Update") { self.text = "Updated" }
            }
        }
        """

        let initial = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        guard case .verticalStack(_, _, let initialChildren) = initial,
              initialChildren.count == 3,
              case .button(_, let updateActionID, _) = initialChildren[1],
              case .button(_, _, _) = initialChildren[2] else {
            return XCTFail("Expected both forwarded binding projections and Update buttons")
        }
        XCTAssertEqual(initialChildren[0], .text("Initial"))

        _ = try await kernel.performAction(updateActionID)
        let updated = try await kernel.lowerViewBody(in: source, typeName: "HostView")
        guard case .verticalStack(_, _, let updatedChildren) = updated,
              updatedChildren.count == 3 else {
            return XCTFail("Expected the forwarded binding to rebuild the host view")
        }
        XCTAssertEqual(updatedChildren[0], .text("Updated"))
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
                VStack {
                    if isVisible { Text(caption) } else { Text("Hidden") }
                    Button("Change caption") { caption = "Changed" }
                    Button("Hide") { isVisible = false }
                }
            }
        }
        """

        let initial = try await kernel.lowerViewBody(in: source, typeName: "StateView")
        guard case .verticalStack(_, _, let initialChildren) = initial,
              initialChildren.count == 3,
              case .button(_, let changeActionID, _) = initialChildren[1] else {
            return XCTFail("Expected StateView controls alongside its state-backed text")
        }
        XCTAssertEqual(initialChildren[0], .text("Initial"))

        _ = try await kernel.performAction(changeActionID)
        let changed = try await kernel.lowerViewBody(in: source, typeName: "StateView")
        guard case .verticalStack(_, _, let changedChildren) = changed,
              changedChildren.count == 3,
              case .button(_, let hideActionID, _) = changedChildren[2] else {
            return XCTFail("Expected refreshed StateView controls")
        }
        XCTAssertEqual(changedChildren[0], .text("Changed"))

        _ = try await kernel.performAction(hideActionID)
        let hidden = try await kernel.lowerViewBody(in: source, typeName: "StateView")
        guard case .verticalStack(_, _, let hiddenChildren) = hidden,
              !hiddenChildren.isEmpty else {
            return XCTFail("Expected the hidden StateView")
        }
        XCTAssertEqual(hiddenChildren[0], .text("Hidden"))

        await kernel.reset()
        let reset = try await kernel.lowerViewBody(in: source, typeName: "StateView")
        guard case .verticalStack(_, _, let resetChildren) = reset,
              !resetChildren.isEmpty else {
            return XCTFail("Expected reset StateView")
        }
        XCTAssertEqual(resetChildren[0], .text("Initial"))
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

    func testLowerViewBodyKeepsSameNamedStateCellsIndependentAcrossViewTypes() async throws {
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

        let second = try await kernel.lowerViewBody(in: secondSource, typeName: "SecondStateView")
        XCTAssertEqual(second, .text("Hidden"))
        let firstAgain = try await kernel.lowerViewBody(in: firstSource, typeName: "FirstStateView")
        XCTAssertEqual(firstAgain, .text("First"))
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

    func testOptionalBindingButtonCapturesTheRenderedValue() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var pendingCaption: String? = \"First\"; var selectedCaption = \"\"")

        let view = try await kernel.lowerViewExpression("""
        if let caption = pendingCaption {
            Button("Select") { selectedCaption = caption }
        }
        """)
        guard case .button(_, let actionID, _) = view else {
            return XCTFail("Expected a button in the selected optional branch")
        }

        _ = try await kernel.evaluate("pendingCaption = \"Later\"")
        _ = try await kernel.performAction(actionID)
        let selected = try await kernel.evaluate("selectedCaption")
        XCTAssertEqual(selected.value, "First")
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
        let finalView = try await kernel.lowerViewBody(in: source, typeName: "ActionView")
        let updatedTapCount = try await kernel.evaluate("tapCount")
        guard case .verticalStack(_, _, let finalChildren) = finalView,
              finalChildren.count == 2 else {
            return XCTFail("Expected ActionView to rebuild after its second action")
        }
        XCTAssertEqual(finalChildren[0], .text("Inactive"))
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
                VStack {
                    if isVisible { Text("Visible") } else { Text("Hidden") }
                    Button("Hide") { isVisible = false }
                }
            }
        }
        """
        let initialStateBody = try await kernel.lowerViewBody(
            in: stateViewSource,
            typeName: "ReloadStateView"
        )
        guard case .verticalStack(_, _, let initialStateChildren) = initialStateBody,
              initialStateChildren.count == 2,
              case .button(_, let hideActionID, _) = initialStateChildren[1] else {
            return XCTFail("Expected reload state view and Hide action")
        }
        XCTAssertEqual(initialStateChildren[0], .text("Visible"))
        _ = try await kernel.performAction(hideActionID)
        let hiddenStateBody = try await kernel.lowerViewBody(
            in: stateViewSource,
            typeName: "ReloadStateView"
        )
        guard case .verticalStack(_, _, let hiddenStateChildren) = hiddenStateBody,
              !hiddenStateChildren.isEmpty else {
            return XCTFail("Expected Hide action to update state before reload")
        }
        XCTAssertEqual(hiddenStateChildren[0], .text("Hidden"))

        try Data("let liveValue = 42\nliveValue".utf8).write(to: sourceURL, options: .atomic)
        let secondRun = try await kernel.reloadAndRun()
        XCTAssertEqual(secondRun.value, "42")
        let reloadedStateBody = try await kernel.lowerViewBody(
            in: stateViewSource,
            typeName: "ReloadStateView"
        )
        guard case .verticalStack(_, _, let reloadedStateChildren) = reloadedStateBody,
              !reloadedStateChildren.isEmpty else {
            return XCTFail("Expected state view after fresh interpreter reload")
        }
        XCTAssertEqual(reloadedStateChildren[0], .text("Visible"))

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

    func testFailedAppReloadRetainsThePreviousStateAndActions() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftInterpreterFailedReloadTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let sourceURL = temporaryRoot.appendingPathComponent("PreviewApp.swift")
        let workspace = try ProjectWorkspaceStore(
            rootURL: temporaryRoot.appendingPathComponent("Workspaces", isDirectory: true)
        ).workspace(for: ProjectID())
        let kernel = InterpreterKernel(workspace: workspace)
        let validSource = """
        import SwiftUI
        @main struct PreviewApp: App {
            var body: some Scene { WindowGroup { PreviewView() } }
        }
        struct PreviewView: View {
            @State private var title = "Initial"
            var body: some View {
                VStack {
                    Text(title)
                    Button("Change") { title = "Changed" }
                }
            }
        }
        """
        try Data(validSource.utf8).write(to: sourceURL)
        _ = try await kernel.linkSourceFile(at: sourceURL)
        let first = try await kernel.reloadAndRunApp()
        guard case .verticalStack(_, _, let children) = first.rootView,
              children.count == 2,
              case .button(_, let actionID, _) = children[1] else {
            return XCTFail("Expected a stateful app with a button")
        }
        _ = try await kernel.performAction(actionID)

        let invalidSource = validSource.replacingOccurrences(
            of: "Text(title)",
            with: "Menu { Text(title) }"
        )
        try Data(invalidSource.utf8).write(to: sourceURL, options: .atomic)
        do {
            _ = try await kernel.reloadAndRunApp()
            XCTFail("Unsupported view must fail the attempted reload")
        } catch {
            // The previously displayed generation must remain usable.
        }

        let restored = try await kernel.refreshAppView(first)
        guard case .verticalStack(_, _, let restoredChildren) = restored.rootView else {
            return XCTFail("Expected the original view after the failed reload")
        }
        XCTAssertEqual(restoredChildren[0], .text("Changed"))
        guard restoredChildren.count == 2,
              case .button(_, let restoredActionID, _) = restoredChildren[1] else {
            return XCTFail("Expected the restored view to keep its button")
        }
        _ = try await kernel.performAction(restoredActionID)

        try Data(validSource.utf8).write(to: sourceURL, options: .atomic)
        let successfulReload = try await kernel.reloadAndRunApp()
        guard case .verticalStack(_, _, let freshChildren) = successfulReload.rootView else {
            return XCTFail("Expected the new session after a successful reload")
        }
        XCTAssertEqual(freshChildren[0], .text("Initial"))
    }

    func testAppViewReceivesHostScenePhaseOnReloadAndRefresh() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftInterpreterScenePhaseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let sourceURL = temporaryRoot.appendingPathComponent("ScenePhaseApp.swift")
        let workspaceRoot = temporaryRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let workspace = try ProjectWorkspaceStore(rootURL: workspaceRoot).workspace(for: ProjectID())
        let kernel = InterpreterKernel(workspace: workspace)
        let source = """
        import SwiftUI

        @main struct ScenePhaseApp: App {
            var body: some Scene { WindowGroup { ScenePhaseView() } }
        }

        struct ScenePhaseView: View {
            @Environment(\\.scenePhase) private var scenePhase

            var body: some View {
                if scenePhase == .active {
                    Text("Active")
                } else if scenePhase == .inactive {
                    Text("Inactive")
                } else {
                    Text("Background")
                }
            }
        }
        """
        try Data(source.utf8).write(to: sourceURL)
        _ = try await kernel.linkSourceFile(at: sourceURL)

        let background = try await kernel.reloadAndRunApp(scenePhase: .background)
        XCTAssertEqual(background.scenePhase, .background)
        XCTAssertEqual(textValues(in: background.rootView), ["Background"])

        let active = try await kernel.refreshAppView(background, scenePhase: .active)
        XCTAssertEqual(active.scenePhase, .active)
        XCTAssertEqual(textValues(in: active.rootView), ["Active"])

        let inactive = try await kernel.refreshAppView(active, scenePhase: .inactive)
        XCTAssertEqual(inactive.scenePhase, .inactive)
        XCTAssertEqual(textValues(in: inactive.rootView), ["Inactive"])

        let backgroundAgain = try await kernel.refreshAppView(inactive, scenePhase: .background)
        XCTAssertEqual(textValues(in: backgroundAgain.rootView), ["Background"])
    }

    func testCustomViewInheritsHostScenePhaseEnvironment() async throws {
        let source = """
        import SwiftUI

        struct ParentView: View {
            var body: some View { ScenePhaseLabel() }
        }

        struct ScenePhaseLabel: View {
            @Environment(\\.scenePhase) private var phase

            var body: some View {
                if phase == .active { Text("Child active") }
                else { Text("Child inactive") }
            }
        }
        """

        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let active = try await kernel.lowerViewBody(
            in: source,
            typeName: "ParentView",
            scenePhase: .active
        )
        XCTAssertEqual(textValues(in: active), ["Child active"])

        let background = try await kernel.lowerViewBody(
            in: source,
            typeName: "ParentView",
            scenePhase: .background
        )
        XCTAssertEqual(textValues(in: background), ["Child inactive"])
    }

    func testDismissEnvironmentButtonReturnsHostDismissalRequest() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct DismissView: View {
            @Environment(\\.dismiss) private var dismiss

            var body: some View {
                HStack {
                    Button("Close") { dismiss() }
                    Button("Stay") { print("staying") }
                }
            }
        }
        """

        let view = try await kernel.lowerViewBody(in: source, typeName: "DismissView")
        guard case .horizontalStack(_, _, let children) = view,
              children.count == 2,
              case .button(_, let closeActionID, _) = children[0],
              case .button(_, let stayActionID, _) = children[1] else {
            return XCTFail("Expected Close and Stay buttons in the lowered view")
        }

        let closeResult = try await kernel.performAction(closeActionID)
        XCTAssertTrue(closeResult.requestsHostDismissal)

        let stayResult = try await kernel.performAction(stayActionID)
        XCTAssertFalse(stayResult.requestsHostDismissal)
        XCTAssertEqual(stayResult.standardOutput, "staying\n")

        let secondCloseResult = try await kernel.performAction(closeActionID)
        XCTAssertTrue(secondCloseResult.requestsHostDismissal)
    }

    func testFailedDismissActionCannotDismissOnLaterTap() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct DismissView: View {
            @Environment(\\.dismiss) private var dismiss
            var body: some View {
                HStack {
                    Button("Fail") {
                        dismiss()
                        missingFunction()
                    }
                    Button("Stay") { print("staying") }
                }
            }
        }
        """

        let view = try await kernel.lowerViewBody(in: source, typeName: "DismissView")
        guard case .horizontalStack(_, _, let children) = view,
              children.count == 2,
              case .button(_, let failedActionID, _) = children[0],
              case .button(_, let stayActionID, _) = children[1] else {
            return XCTFail("Expected both actions")
        }

        do {
            _ = try await kernel.performAction(failedActionID)
            XCTFail("The missing function must fail")
        } catch {
            // The first statement already requested dismissal when execution failed.
        }

        let nextResult = try await kernel.performAction(stayActionID)
        XCTAssertFalse(nextResult.requestsHostDismissal)
        XCTAssertEqual(nextResult.standardOutput, "staying\n")
    }

    func testCustomViewDismissEnvironmentInheritsHostContext() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct ParentView: View {
            var body: some View { DismissChildView() }
        }

        struct DismissChildView: View {
            @Environment(\\.dismiss) private var dismiss

            var body: some View {
                Button("Close child") { self.dismiss() }
            }
        }
        """

        let view = try await kernel.lowerViewBody(in: source, typeName: "ParentView")
        guard case .button(_, let actionID, _) = view else {
            return XCTFail("Expected the custom child to lower as a button")
        }

        let result = try await kernel.performAction(actionID)
        XCTAssertTrue(result.requestsHostDismissal)
    }

    func testDismissEnvironmentMustBeInvokedDirectly() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct DismissAliasView: View {
            @Environment(\\.dismiss) private var dismiss

            var body: some View {
                Button("Close") {
                    let close = dismiss
                    close()
                }
            }
        }
        """

        do {
            _ = try await kernel.lowerViewBody(in: source, typeName: "DismissAliasView")
            XCTFail("Only direct dismiss() calls are connected to the native host action")
        } catch let error as RuntimeViewLoweringError {
            guard case .unsupportedExpression(let detail) = error else {
                return XCTFail("Expected a clear unsupported-expression diagnostic")
            }
            XCTAssertTrue(detail.contains("must be invoked directly"))
        }
    }

    private func textValues(in node: RuntimeViewNode) -> [String] {
        switch node {
        case .text(let value):
            return [value]
        case .group(let children), .verticalStack(_, _, let children), .horizontalStack(_, _, let children):
            return children.flatMap { textValues(in: $0) }
        case .forEach(let items):
            return items.flatMap { textValues(in: $0.content) }
        case .modified(let content, _):
            return textValues(in: content)
        default:
            return []
        }
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
