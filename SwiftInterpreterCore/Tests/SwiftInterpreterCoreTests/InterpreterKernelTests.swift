import Foundation
import XCTest
@testable import SwiftInterpreterCore

final class InterpreterKernelTests: XCTestCase {
    func testToolbarOpensHistoryAndSettingsAndDismissalWritesBack() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct RootView: View {
            @State private var history = false
            @State private var settings = false
            @State private var notice = false
            @Environment(\\.dismiss) private var dismiss
            var body: some View {
                NavigationStack {
                    Text("Chat")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Verlauf") { history = true }
                            }
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                Button("Einstellungen") { settings = true }
                                Button("Hinweis") { notice = true }
                            }
                        }
                }
                .sheet(isPresented: $history) {
                    NavigationStack {
                        Text("Chatverlauf").navigationTitle("Chatverlauf")
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Fertig") { dismiss() }
                                }
                            }
                    }
                }
                .sheet(isPresented: $settings) {
                    NavigationStack { Form { Text("Einstellungen") } }
                }
                .alert("Hinweis", isPresented: $notice) {
                    Button("OK", role: .cancel) {}
                } message: { Text("Eine Nachricht") }
            }
        }
        """
        let first = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .modified(content: .modified(content: .modified(content: .navigationStack(
                            .modified(content: .modified(content: .text("Chat"), modifier: .navigationBarTitleDisplayModeInline),
                                      modifier: .toolbar(let toolbar))),
                            modifier: .sheet(_, let historyID, _)),
                            modifier: .sheet(_, _, _)),
                            modifier: .alert(_, _, _, _, _)) = first,
              case .button(_, let openHistory, _) = toolbar[0].content,
              case .group(let trailing) = toolbar[1].content,
              case .button(_, let openSettings, _) = trailing[0],
              case .button(_, let openNotice, _) = trailing[1] else {
            return XCTFail("Expected functional navigation toolbar and presentations")
        }
        _ = try await kernel.performAction(openHistory)
        let shown = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .modified(content: .modified(content: .modified(_, modifier: .sheet(true, let activeHistoryID, let historyContent)), modifier: .sheet), modifier: .alert) = shown,
              case .navigationStack(.modified(_, modifier: .toolbar(let finishItems))) = historyContent,
              case .button(_, let finish, _) = finishItems[0].content else {
            return XCTFail("History sheet should be shown with its dismiss button")
        }
        XCTAssertNotEqual(historyID, activeHistoryID)
        let result = try await kernel.performAction(finish)
        XCTAssertTrue(result.requestsHostDismissal)
        _ = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        try await kernel.setPresentation(activeHistoryID, isPresented: false)
        let newNavigation = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .modified(content: .modified(content: .modified(_, modifier: .sheet(false, _, _)), modifier: .sheet), modifier: .alert) = newNavigation else {
            return XCTFail("Dismissed history must stay closed")
        }
        guard case .modified(content: .modified(content: .modified(content: .navigationStack(
                            .modified(_, modifier: .toolbar(let updatedToolbar))), modifier: .sheet),
                            modifier: .sheet(_, let settingsID, _)), modifier: .alert(_, _, let noticeID, _, _)) = newNavigation,
              case .group(let updatedTrailing) = updatedToolbar[1].content,
              case .button(_, let settingsButton, _) = updatedTrailing[0],
              case .button(_, let noticeButton, _) = updatedTrailing[1] else {
            return XCTFail("Toolbar actions should refresh with the view")
        }
        _ = try await kernel.performAction(settingsButton)
        let settingsShown = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .modified(content: .modified(_, modifier: .sheet(true, let activeSettingsID, _)), modifier: .alert) = settingsShown else {
            return XCTFail("Settings sheet should open")
        }
        XCTAssertNotEqual(settingsID, activeSettingsID)
        try await kernel.setPresentation(activeSettingsID, isPresented: false)
        let settingsClosed = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .modified(content: .modified(content: .modified(content: .navigationStack(
                            .modified(_, modifier: .toolbar(let currentToolbar))), modifier: .sheet),
                            modifier: .sheet(false, _, _)), modifier: .alert) = settingsClosed,
              case .group(let currentTrailing) = currentToolbar[1].content,
              case .button(_, let currentNoticeButton, _) = currentTrailing[1] else {
            return XCTFail("Settings dismissal should write back")
        }
        _ = try await kernel.performAction(currentNoticeButton)
        let noticeShown = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .modified(_, modifier: .alert("Hinweis", true, let activeNoticeID, _, .text("Eine Nachricht"))) = noticeShown else {
            return XCTFail("Alert should open with its message")
        }
        XCTAssertNotEqual(noticeID, activeNoticeID)
        try await kernel.setPresentation(activeNoticeID, isPresented: false)
        _ = openSettings
        _ = openNotice
        _ = noticeButton
    }

    func testItemSheetBindsChallengeAndClearsItOnDismissal() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        struct Challenge { var id: String; var code: String }
        var challenge: Challenge? = nil
        """)
        let source = """
        Text("Anmeldung")
            .sheet(item: $challenge) { current in
                NavigationStack {
                    VStack {
                        Text(current.code)
                        Button("Abbrechen", role: .cancel) { challenge = nil }
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        """
        let empty = try await kernel.lowerViewExpression(source)
        guard case .modified(_, modifier: .itemSheet(nil, _, .empty)) = empty else {
            return XCTFail("Unpresented item sheet should not evaluate its content")
        }
        _ = try await kernel.evaluate("challenge = Challenge(id: \"login-1\", code: \"ABCD\")")
        let shown = try await kernel.lowerViewExpression(source)
        guard case .modified(_, modifier: .itemSheet(let item?, let inputID,
                    .modified(content: .modified(content: .navigationStack(.verticalStack(_, _, let children)),
                    modifier: .presentationDetentsMedium), modifier: .presentationDragIndicatorVisible))) = shown,
              case .text("ABCD") = children[0],
              case .button(_, let cancelID, _) = children[1] else {
            return XCTFail("The sheet should bind the current challenge to its body")
        }
        XCTAssertEqual(item.id, RuntimeForEachID(rawValue: "6:String7:login-1"))
        _ = try await kernel.performAction(cancelID)
        let closed = try await kernel.lowerViewExpression(source)
        guard case .modified(_, modifier: .itemSheet(nil, _, _)) = closed else {
            return XCTFail("Cancellation should close the item sheet")
        }
        _ = try await kernel.evaluate("challenge = Challenge(id: \"login-2\", code: \"EFGH\")")
        let reopened = try await kernel.lowerViewExpression(source)
        guard case .modified(_, modifier: .itemSheet(_, let reopenedInputID, _)) = reopened else {
            return XCTFail("Expected reopened item sheet")
        }
        try await kernel.setPresentation(reopenedInputID, isPresented: true)
        let stillPresented = try await kernel.lowerViewExpression(source)
        guard case .modified(_, modifier: .itemSheet(let current?, _, _)) = stillPresented else {
            return XCTFail("Writing the current item must not clear its binding")
        }
        XCTAssertEqual(current.id, RuntimeForEachID(rawValue: "6:String7:login-2"))
        try await kernel.setPresentation(reopenedInputID, isPresented: false)
        let challengeState = try await kernel.evaluate("challenge == nil")
        XCTAssertEqual(challengeState.value, "true")
        _ = inputID
    }

    func testOnAppearAndOnChangeCaptureNewValueAndScrollRequest() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var phase = \"idle\"; var seen = \"\"; var appeared = 0")
        let source = """
        ScrollViewReader { proxy in
            Text("Status")
                .id("end")
                .onAppear { appeared += 1 }
                .onChange(of: phase) { next in
                    seen = next
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
        }
        """
        let initial = try await kernel.lowerViewExpression(source)
        guard case .scrollViewReader(_, .modified(content: .modified(_, modifier: .onAppear(let appearID)),
                       modifier: .onChange("idle", _))) = initial else {
            return XCTFail("Expected registered view events")
        }
        _ = try await kernel.performAction(appearID)
        let appearances = try await kernel.evaluate("appeared")
        XCTAssertEqual(appearances.value, "1")
        _ = try await kernel.evaluate("phase = \"ready\"")
        let refreshed = try await kernel.lowerViewExpression(source)
        guard case .scrollViewReader(_, .modified(_, modifier: .onChange("ready", let changeID))) = refreshed else {
            return XCTFail("onChange should observe the updated state")
        }
        let result = try await kernel.performAction(changeID)
        let observed = try await kernel.evaluate("seen")
        XCTAssertEqual(observed.value, "ready")
        XCTAssertEqual(result.scrollRequest?.anchor, .bottom)
    }

    func testOnChangeObservesHostScenePhaseAndRunsFlushAction() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var flushes = 0")
        let source = """
        struct RootView: View {
            @Environment(\\.scenePhase) private var scenePhase
            var body: some View {
                Text("Chat").onChange(of: scenePhase) { phase in
                    if phase != .active { flushes += 1 }
                }
            }
        }
        """
        let active = try await kernel.lowerViewBody(in: source, typeName: "RootView", scenePhase: .active)
        guard case .modified(_, modifier: .onChange(let activeValue, _)) = active else {
            return XCTFail("Expected active scene event")
        }
        let inactive = try await kernel.lowerViewBody(in: source, typeName: "RootView", scenePhase: .inactive)
        guard case .modified(_, modifier: .onChange(let inactiveValue, let actionID)) = inactive else {
            return XCTFail("Expected updated scene event")
        }
        XCTAssertNotEqual(activeValue, inactiveValue)
        _ = try await kernel.performAction(actionID)
        let flushes = try await kernel.evaluate("flushes")
        XCTAssertEqual(flushes.value, "1")
    }

    func testOnChangeConnectionEnumMatchesItsImplicitCase() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        enum Connection { case signedOut; case connected }
        var state = Connection.signedOut
        var refreshes = 0
        """)
        let source = """
        Text("Modell").onChange(of: state) { current in
            if current == .connected { refreshes += 1 }
        }
        """
        _ = try await kernel.lowerViewExpression(source)
        _ = try await kernel.evaluate("state = Connection.connected")
        let refreshed = try await kernel.lowerViewExpression(source)
        guard case .modified(_, modifier: .onChange(_, let actionID)) = refreshed else {
            return XCTFail("Expected connection change action")
        }
        _ = try await kernel.performAction(actionID)
        let result = try await kernel.evaluate("refreshes")
        XCTAssertEqual(result.value, "1")
    }

    func testDeviceLinkTracksCurrentDestination() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var destination = \"https://example.com/device/one\"")
        let source = "Link(destination: destination) { Text(\"Anmeldeseite öffnen\") }"
        let first = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(first,
                       .link(destination: "https://example.com/device/one", label: .text("Anmeldeseite öffnen")))
        _ = try await kernel.evaluate("destination = \"https://example.com/device/two\"")
        let second = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(second,
                       .link(destination: "https://example.com/device/two", label: .text("Anmeldeseite öffnen")))
    }

    func testNamedRootViewMethodIsPassedToComposerButton() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var sent = \"\"")
        let source = """
        struct RootView: View {
            @State private var draft = "Bereit"
            var body: some View {
                Composer(text: $draft, onSend: sendDraft)
            }
            private func sendDraft() {
                sent = draft
                draft = ""
            }
        }
        struct Composer: View {
            @Binding var text: String
            let onSend: () -> Void
            var body: some View {
                VStack {
                    TextField("Nachricht", text: $text)
                    Button(action: onSend) { Text("Senden") }
                }
            }
        }
        """
        let first = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .verticalStack(_, _, let children) = first,
              case .button(_, let sendID, _) = children[1] else {
            return XCTFail("Expected named composer callback")
        }
        _ = try await kernel.performAction(sendID)
        let sent = try await kernel.evaluate("sent")
        XCTAssertEqual(sent.value, "Bereit")
        let updated = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .verticalStack(_, _, let refreshed) = updated,
              case .textField(_, let value, _, _) = refreshed[0] else {
            return XCTFail("Expected composer to refresh")
        }
        XCTAssertEqual(value, "")
    }

    func testComputedSelectorValuesFeedDynamicMenuButtons() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var selected = \"auto\"")
        let source = """
        struct RootView: View {
            var body: some View {
                ModelMenu(levels: ["low", "high"])
            }
        }
        struct ModelMenu: View {
            let levels: [String]
            private var reasoningLevels: [String] {
                let reported = levels
                return reported.isEmpty ? ["medium"] : reported
            }
            var body: some View {
                Menu {
                    ForEach(reasoningLevels, id: \\.self) { level in
                        Button(level.capitalized) { selected = level }
                    }
                } label: { Text(selected) }
            }
        }
        """
        let first = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .menu(_, .forEach(let items)) = first,
              items.count == 2,
              case .button(let label, let actionID, _) = items[1].content else {
            return XCTFail("Expected computed levels in the menu")
        }
        XCTAssertEqual(label, .text("High"))
        _ = try await kernel.performAction(actionID)
        let selected = try await kernel.evaluate("selected")
        XCTAssertEqual(selected.value, "high")
    }

    func testLocalBuilderValueFeedsReasoningPickerAndBinding() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("let reportedLevels = [\"low\", \"high\"]; var selected = \"low\"")
        let source = """
        Form {
            Section("Reasoning") {
                let levels = reportedLevels
                if levels.isEmpty {
                    Text("Keine Stufen")
                } else {
                    Picker("Stufe", selection: Binding(get: { selected }, set: { selected = $0 })) {
                        ForEach(levels, id: \\.self) { level in
                            Text(level.capitalized).tag(level)
                        }
                    }
                }
            }
        }
        """
        let first = try await kernel.lowerViewExpression(source)
        guard case .form(.section(_, .picker(_, let selection, let id, .forEach(let rows)))) = first else {
            return XCTFail("Expected locally aliased picker options")
        }
        XCTAssertEqual(selection, "low")
        XCTAssertEqual(rows.count, 2)
        try await kernel.setInput(id, to: "high")
        let selected = try await kernel.evaluate("selected")
        XCTAssertEqual(selected.value, "high")
    }

    func testDynamicComposerImageAndBackgroundRefreshWithState() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var canSend = false")
        let source = """
        HStack {
            Image(systemName: canSend ? "arrow.up" : "mic")
            ProgressView()
            Button("Toggle") { canSend = !canSend }
                .background(canSend ? Color.primary : Color.secondary.opacity(0.35), in: Circle())
        }
        """
        let first = try await kernel.lowerViewExpression(source)
        guard case .horizontalStack(_, _, let children) = first,
              case .modified(content: .button(_, let actionID, _),
                             modifier: .background(let style, _)) = children[2] else {
            return XCTFail("Expected dynamic composer controls")
        }
        XCTAssertEqual(children[0], .image(systemName: "mic"))
        XCTAssertEqual(children[1], .progressView)
        XCTAssertEqual(style, .color(RuntimeColorValue(style: .secondary, opacity: 0.35)))
        _ = try await kernel.performAction(actionID)
        let refreshed = try await kernel.lowerViewExpression(source)
        guard case .horizontalStack(_, _, let updated) = refreshed,
              case .modified(content: .button, modifier: .background(let updatedStyle, _)) = updated[2] else {
            return XCTFail("Expected updated composer controls")
        }
        XCTAssertEqual(updated[0], .image(systemName: "arrow.up"))
        XCTAssertEqual(updatedStyle, .color(RuntimeColorValue(style: .primary)))
    }

    func testSettingsReasoningChoicesUseComputedGuardAndLocalAlias() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        struct Model {
            var id: String
            var supportedReasoningLevels: [String]
        }
        let models = [
            Model(id: "a", supportedReasoningLevels: ["low"]),
            Model(id: "b", supportedReasoningLevels: ["medium", "high"])
        ]
        let selectedID: String? = "b"
        """)
        let source = """
        struct RootView: View {
            @State private var reasoning = "medium"
            var body: some View {
                ReasoningForm(models: models, selectedID: selectedID, reasoning: $reasoning)
            }
        }
        struct ReasoningForm: View {
            let models: [Model]
            let selectedID: String?
            @Binding var reasoning: String
            private var selectedReasoningLevels: [String] {
                guard let id = selectedID,
                      let model = models.first(where: { $0.id == id }) else { return [] }
                return model.supportedReasoningLevels
            }
            var body: some View {
                Form {
                    Section("Reasoning") {
                        let levels = selectedReasoningLevels
                        if levels.isEmpty {
                            Text("Keine Stufen")
                        } else {
                            Picker("Stufe", selection: $reasoning) {
                                ForEach(levels, id: \\.self) { level in
                                    Text(level.capitalized).tag(level)
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        let initial = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .form(.section(_, .picker(_, let selection, let inputID, .forEach(let rows)))) = initial else {
            return XCTFail("Expected settings reasoning form")
        }
        XCTAssertEqual(selection, "medium")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].content, .modified(content: .text("High"), modifier: .tag("high")))
        try await kernel.setInput(inputID, to: "high")
        let updated = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .form(.section(_, .picker(_, let selected, _, _))) = updated else {
            return XCTFail("Expected refreshed settings picker")
        }
        XCTAssertEqual(selected, "high")
    }

    func testTextFieldAndPickerWriteThroughBindingAndRefreshState() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct InputView: View {
            @State private var draft = ""
            @State private var reasoning = "auto"

            var body: some View {
                Form {
                    Section("Eingaben") {
                        TextField("Nachricht schreiben", text: $draft, axis: .vertical)
                        Text(draft)
                        Picker("Stufe", selection: $reasoning) {
                            Text("Automatisch").tag("auto")
                            Text("Hoch").tag("high")
                        }
                        Text(reasoning)
                    }
                }
            }
        }
        """
        let first = try await kernel.lowerViewBody(in: source, typeName: "InputView")
        guard case .form(.section(_, .group(let children))) = first,
              case .textField(_, let draft, let textID, _) = children[0],
              case .picker(_, let selection, let pickerID, _) = children[2] else {
            return XCTFail("Expected bound inputs")
        }
        XCTAssertEqual(draft, "")
        XCTAssertEqual(selection, "auto")
        try await kernel.setInput(textID, to: "Hallo")
        try await kernel.setInput(pickerID, to: "high")

        let refreshed = try await kernel.lowerViewBody(in: source, typeName: "InputView")
        guard case .form(.section(_, .group(let updated))) = refreshed,
              case .textField(_, let updatedDraft, _, _) = updated[0],
              case .picker(_, let updatedSelection, _, _) = updated[2] else {
            return XCTFail("Expected refreshed bound inputs")
        }
        XCTAssertEqual(updatedDraft, "Hallo")
        XCTAssertEqual(updated[1], .text("Hallo"))
        XCTAssertEqual(updatedSelection, "high")
        XCTAssertEqual(updated[3], .text("high"))
    }

    func testComputedPickerBindingRunsSetterAndDynamicChoiceTags() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var selected = \"auto\"; let levels = [\"low\", \"high\"]")
        let source = """
        Picker("Stufe", selection: Binding(get: { selected }, set: { selected = $0 })) {
            Text("Automatisch").tag("auto")
            ForEach(levels, id: \\.self) { level in
                Text(level.capitalized).tag(level)
            }
        }
        """
        let first = try await kernel.lowerViewExpression(source)
        guard case .picker(_, let original, let inputID, let content) = first,
              case .group(let choices) = content,
              case .forEach(let rows) = choices[1] else {
            return XCTFail("Expected expanded picker choices")
        }
        XCTAssertEqual(original, "auto")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].content, .modified(content: .text("High"), modifier: .tag("high")))
        try await kernel.setInput(inputID, to: "high")
        let selected = try await kernel.evaluate("selected")
        XCTAssertEqual(selected.value, "high")
    }

    func testCustomViewCallbackCanClearComposedBinding() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct RootView: View {
            @State private var draft = "Ready"
            var body: some View {
                Composer(text: $draft, onSend: { draft = "" })
            }
        }
        struct Composer: View {
            @Binding var text: String
            let onSend: () -> Void
            var body: some View {
                VStack {
                    TextField("Nachricht", text: $text)
                    Button(action: onSend) { Text("Senden") }
                }
            }
        }
        """
        let first = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .verticalStack(_, _, let children) = first,
              case .button(_, let actionID, _) = children[1] else {
            return XCTFail("Expected callback button")
        }
        _ = try await kernel.performAction(actionID)
        let refreshed = try await kernel.lowerViewBody(in: source, typeName: "RootView")
        guard case .verticalStack(_, _, let updated) = refreshed,
              case .textField(_, let value, _, _) = updated[0] else {
            return XCTFail("Expected composer input")
        }
        XCTAssertEqual(value, "")
    }

    func testMenuModelButtonsUseDynamicTitlesAndCaptureTheirRowActions() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var selected = \"Automatisch\"; let models = [\"Modell A\", \"Modell B\"]")
        let source = """
        Menu {
            ForEach(models, id: \\.self) { model in
                Button(model) { selected = model }
            }
        } label: {
            Text(selected)
        }
        """
        let initial = try await kernel.lowerViewExpression(source)
        guard case .menu(let label, .forEach(let rows)) = initial,
              rows.count == 2,
              case .button(let firstTitle, _, _) = rows[0].content,
              case .button(let secondTitle, let secondID, _) = rows[1].content else {
            return XCTFail("Expected two dynamic model buttons")
        }
        XCTAssertEqual(label, .text("Automatisch"))
        XCTAssertEqual(firstTitle, .text("Modell A"))
        XCTAssertEqual(secondTitle, .text("Modell B"))
        _ = try await kernel.performAction(secondID)
        let selected = try await kernel.evaluate("selected")
        XCTAssertEqual(selected.value, "Modell B")
        let refreshed = try await kernel.lowerViewExpression(source)
        guard case .menu(let updatedLabel, _) = refreshed else {
            return XCTFail("Expected refreshed model menu")
        }
        XCTAssertEqual(updatedLabel, .text("Modell B"))
    }

    func testTextFieldOnSubmitKeepsItsConditionalInsideTheAction() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let source = """
        struct ComposerView: View {
            @State private var draft = ""
            var body: some View {
                TextField("Nachricht", text: $draft).onSubmit {
                    if !draft.isEmpty { draft = "" }
                }
            }
        }
        """
        let first = try await kernel.lowerViewBody(in: source, typeName: "ComposerView")
        guard case .modified(content: .textField(_, _, let inputID, _), modifier: .onSubmit(let actionID)) = first else {
            return XCTFail("Expected submit action attached to the text field")
        }
        try await kernel.setInput(inputID, to: "Nachricht")
        _ = try await kernel.performAction(actionID)
        let refreshed = try await kernel.lowerViewBody(in: source, typeName: "ComposerView")
        guard case .modified(content: .textField(_, let value, _, _), modifier: .onSubmit) = refreshed else {
            return XCTFail("Expected refreshed text field")
        }
        XCTAssertEqual(value, "")
    }

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

        let shorthand = try await kernel.lowerViewExpression(
            #"ForEach(levels, id: \.self) { Text($0.capitalized) }"#
        )
        guard case .forEach(let shorthandItems) = shorthand else {
            return XCTFail("Expected a shorthand-argument ForEach node")
        }
        XCTAssertEqual(shorthandItems.map(\.content), [.text("Low"), .text("High")])
        XCTAssertEqual(shorthandItems.map(\.id.rawValue), levelItems.map(\.id.rawValue))

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

    func testScrollViewAndLazyStackRefreshIdentifiedRows() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        struct Row: Identifiable { let id: String; let title: String }
        var rows = [Row(id: "a", title: "Alpha"), Row(id: "b", title: "Beta")]
        """)
        let source = """
        ScrollView {
            LazyVStack(spacing: 22) {
                ForEach(rows) { row in Text(row.title).id(row.id) }
            }
        }
        """
        let initial = try await kernel.lowerViewExpression(source)
        guard case .scrollView(.vertical, true, .lazyVerticalStack(_, let spacing, let children)) = initial,
              spacing == 22,
              children.count == 1,
              case .forEach(let items) = children[0] else {
            return XCTFail("Expected an identified collection inside a lazy scroll stack")
        }
        XCTAssertEqual(items.map(\.id.rawValue), ["6:String1:a", "6:String1:b"])
        XCTAssertEqual(items[0].content, .modified(content: .text("Alpha"), modifier: .id(items[0].id)))

        _ = try await kernel.evaluate("rows = [rows[1], Row(id: \"c\", title: \"Gamma\")]")
        let updated = try await kernel.lowerViewExpression(source)
        guard case .scrollView(_, _, .lazyVerticalStack(_, _, let refreshedChildren)) = updated,
              case .some(.forEach(let refreshed)) = refreshedChildren.first else {
            return XCTFail("Expected the refreshed scroll content")
        }
        XCTAssertEqual(refreshed.map(\.id.rawValue), ["6:String1:b", "6:String1:c"])
    }

    func testScrollReaderRoutesProxyRequestToStableRowID() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        struct Row: Identifiable { let id: String; let title: String }
        let rows = [Row(id: "first", title: "Alpha"), Row(id: "last", title: "Omega")]
        """)
        let source = """
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack {
                    ForEach(rows) { row in
                        Button("Jump") { proxy.scrollTo(row.id, anchor: .bottom) }
                    }
                    Color.clear.id("chat-bottom")
                }
            }
        }
        """
        let view = try await kernel.lowerViewExpression(source)
        guard case .scrollViewReader(let readerID, .scrollView(_, _, .lazyVerticalStack(_, _, let children))) = view,
              children.count == 2,
              case .forEach(let items) = children[0],
              items.count == 2,
              case .button(_, let secondActionID, _) = items[1].content,
              case .modified(_, .id(let bottomID)) = children[1] else {
            return XCTFail("Expected the reader, row actions, and bottom scroll anchor")
        }
        XCTAssertEqual(bottomID.rawValue, "6:String11:chat-bottom")

        let result = try await kernel.performAction(secondActionID)
        XCTAssertEqual(result.scrollRequest?.readerID, readerID)
        XCTAssertEqual(result.scrollRequest?.targetID, items[1].id)
        XCTAssertEqual(result.scrollRequest?.anchor, .bottom)
        XCTAssertFalse(result.requestsHostDismissal)
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
            XCTAssertEqual(error, .unsupportedArgument("Menu"))
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

    func testAppBootstrapSharesOwnedObjectsAndExpandsBuilderHelpers() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftInterpreterObservableApp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let sourceURL = temporaryRoot.appendingPathComponent("ObservableApp.swift")
        let workspace = try ProjectWorkspaceStore(
            rootURL: temporaryRoot.appendingPathComponent("Workspaces", isDirectory: true)
        ).workspace(for: ProjectID())
        let kernel = InterpreterKernel(workspace: workspace)
        let source = """
        import SwiftUI
        enum Login { case connected, failed(String) }
        final class Session: ObservableObject {
            @Published var state: Login = .connected
            func fail() { state = .failed("Expired") }
        }
        final class Store: ObservableObject {
            @Published var title = "First"
            let session: Session
            init(session: Session) { self.session = session }
            func change() { title = "Changed"; session.fail() }
        }
        @main struct ObservableApp: App {
            var body: some Scene { WindowGroup { ContentView() } }
        }
        struct ContentView: View {
            @StateObject private var session: Session
            @StateObject private var store: Store
            init() {
                let session = Session()
                _session = StateObject(wrappedValue: session)
                _store = StateObject(wrappedValue: Store(session: session))
            }
            var body: some View {
                VStack {
                    Text(store.title)
                    conversationBody
                    SettingsView(store: store, session: session)
                    Button("Change") { store.change() }
                }
            }
            @ViewBuilder private var conversationBody: some View {
                if store.title == "Changed" {
                    Text("Updated")
                } else {
                    Text("Waiting")
                }
            }
        }
        struct SettingsView: View {
            @ObservedObject var store: Store
            @ObservedObject var session: Session
            @State private var note = "Stable"
            var body: some View {
                VStack {
                    Text(store.title)
                    Text(note)
                    authSummary
                }
            }
            @ViewBuilder private var authSummary: some View {
                switch session.state {
                case .connected: Text("Connected")
                case .failed(let message): Text(message)
                }
            }
        }
        """
        try Data(source.utf8).write(to: sourceURL)
        _ = try await kernel.linkSourceFile(at: sourceURL)
        let first = try await kernel.reloadAndRunApp()
        XCTAssertEqual(textValues(in: first.rootView), [
            "First", "Waiting", "First", "Stable", "Connected"
        ])

        let changes = await kernel.publishedChanges()
        guard case .verticalStack(_, _, let children) = first.rootView,
              case .button(_, let changeAction, _) = children.last else {
            return XCTFail("Expected the shared Store action")
        }
        _ = try await kernel.performAction(changeAction)
        var iterator = changes.makeAsyncIterator()
        let revision = await iterator.next()
        XCTAssertNotNil(revision)
        let refreshed = try await kernel.refreshAppView(first)
        XCTAssertEqual(textValues(in: refreshed.rootView), [
            "Changed", "Updated", "Changed", "Stable", "Expired"
        ])
        let reloaded = try await kernel.reloadAndRunApp()
        XCTAssertEqual(textValues(in: reloaded.rootView), [
            "First", "Waiting", "First", "Stable", "Connected"
        ])
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

    func testTargetFoundationURLAndStringConversions() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate(#"""
        import Foundation
        let base = URL(string: "https://example.com/api")!
        let endpoint = base.appendingPathComponent("models", isDirectory: true)
        let missing = URL(string: "http://[") == nil
        let clean = "  hello WORLD \n".trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = "a b".addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz"))!
        "\(endpoint.absoluteString)|\(missing)|\(clean.capitalized)|\(clean.lowercased())|\(encoded)|\(clean.replacingOccurrences(of: "WORLD", with: "Swift"))"
        """#)
        XCTAssertEqual(result.value, "https://example.com/api/models/|true|Hello World|hello world|a%20b|hello Swift")
    }

    func testTargetFoundationDataAndBase64Conversions() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate(#"""
        import Foundation
        var bytes = Data("Hi".utf8)
        bytes.append(Data("!".utf8))
        let encoded = bytes.base64EncodedString()
        let decoded = Data(base64Encoded: encoded)!
        let invalid = Data(base64Encoded: "not base64?") == nil
        let text = String(data: decoded, encoding: .utf8)!
        let textData = text.data(using: .utf8)!
        "\(encoded)|\(text)|\(textData.count)|\(invalid)"
        """#)
        XCTAssertEqual(result.value, "SGkh|Hi!|3|true")
    }

    func testTargetFoundationDatesAndIdentifiers() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate(#"""
        import Foundation
        let start = Date(timeIntervalSince1970: 1000)
        let later = start.addingTimeInterval(900)
        let id = UUID()
        let restored = UUID(uuidString: id.uuidString)!
        let invalid = UUID(uuidString: "invalid") == nil
        let display = later.formatted(date: .abbreviated, time: .shortened)
        "\(later > start)|\(later.timeIntervalSince(start))|\(restored == id)|\(invalid)|\(!display.isEmpty)"
        """#)
        XCTAssertEqual(result.value, "true|900.0|true|true|true")
    }

    func testTargetFoundationCodableConversationRoundTrip() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate(#"""
        import Foundation
        enum ChatRole: String, Codable { case user, assistant }
        struct ChatMessage: Codable {
            var id: UUID
            var role: ChatRole
            var text: String
            var createdAt: Date
            var modelID: String?
        }
        struct ChatConversation: Codable {
            var id: UUID
            var messages: [ChatMessage]
        }
        let id = UUID()
        let message = ChatMessage(id: id, role: .assistant, text: "hello", createdAt: Date(timeIntervalSince1970: 1000), modelID: nil)
        let original = ChatConversation(id: id, messages: [message])
        let bytes = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ChatConversation.self, from: bytes)
        "\(restored.id == id)|\(restored.messages[0].role == .assistant)|\(restored.messages[0].role != .user)|\(restored.messages[0].text)|\(restored.messages[0].modelID == nil)|\(restored.messages[0].createdAt.timeIntervalSince1970)"
        """#)
        XCTAssertEqual(result.value, "true|true|true|hello|true|1000.0")
    }

    func testTargetFoundationUntypedJSONRoundTrip() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let result = try await kernel.evaluate(#"""
        import Foundation
        let data = try JSONSerialization.data(withJSONObject: ["client_id": "abc", "enabled": true, "count": 3])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let client = object["client_id"] as? String ?? "missing"
        let enabled = object["enabled"] as? Bool ?? false
        let count = object["count"] as? Int ?? 0
        "\(client)|\(enabled)|\(count)"
        """#)
        XCTAssertEqual(result.value, "abc|true|3")
    }

    func testTargetPersistenceRoundTripsWithinProjectAndSurvivesKernelRestart() async throws {
        let workspace = try makeWorkspace()
        let declarations = #"""
        import Foundation
        struct ChatPreferences: Codable { var selectedModelID: String? }
        struct ChatIndex: Codable {
            var conversationIDs: [UUID]
            var activeConversationID: UUID?
            var preferences: ChatPreferences
        }
        struct ChatConversation: Codable { var id: UUID; var title: String }
        final class JSONChatPersistence {
            private let rootURL: URL
            private let fileManager = FileManager.default
            init(rootURL: URL) { self.rootURL = rootURL }

            static func makeDefault() -> JSONChatPersistence {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                return JSONChatPersistence(rootURL: support.appendingPathComponent("SwiftChat", isDirectory: true))
            }
            func loadIndex() throws -> ChatIndex {
                let url = rootURL.appendingPathComponent("index.json")
                return try JSONDecoder().decode(ChatIndex.self, from: Data(contentsOf: url))
            }
            func saveIndex(_ index: ChatIndex) throws {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(index)
                try data.write(to: rootURL.appendingPathComponent("index.json"), options: .atomic)
            }
            func loadConversation(id: UUID) throws -> ChatConversation? {
                let url = rootURL.appendingPathComponent("Conversations", isDirectory: true)
                    .appendingPathComponent("conversation-\(id.uuidString).json")
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return try JSONDecoder().decode(ChatConversation.self, from: Data(contentsOf: url))
            }
            func saveConversation(_ conversation: ChatConversation) throws {
                let folder = rootURL.appendingPathComponent("Conversations", isDirectory: true)
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(conversation)
                try data.write(to: folder.appendingPathComponent("conversation-\(conversation.id.uuidString).json"), options: .atomic)
            }
            func deleteConversation(id: UUID) throws {
                let url = rootURL.appendingPathComponent("Conversations", isDirectory: true)
                    .appendingPathComponent("conversation-\(id.uuidString).json")
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
        }
        """#
        let id = "a179b210-1abd-41a8-8c84-4e5430ac143c"
        let first = InterpreterKernel(workspace: workspace)
        let saved = try await first.evaluate(declarations + "\n" + #"""
        let persistence = JSONChatPersistence.makeDefault()
        let id = UUID(uuidString: "a179b210-1abd-41a8-8c84-4e5430ac143c")!
        try persistence.saveIndex(ChatIndex(conversationIDs: [id], activeConversationID: id, preferences: ChatPreferences(selectedModelID: "gpt")))
        try persistence.saveConversation(ChatConversation(id: id, title: "Erster Chat"))
        try persistence.loadConversation(id: id) != nil
        """#)
        XCTAssertEqual(saved.value, "true")

        let supportURL = workspace.rootURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SwiftChat", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportURL.appendingPathComponent("index.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportURL
            .appendingPathComponent("Conversations", isDirectory: true)
            .appendingPathComponent("conversation-\(id.uppercased()).json").path))

        let reopened = InterpreterKernel(workspace: workspace)
        let loaded = try await reopened.evaluate(declarations + "\n" + #"""
        let persistence = JSONChatPersistence.makeDefault()
        let id = UUID(uuidString: "a179b210-1abd-41a8-8c84-4e5430ac143c")!
        let index = try persistence.loadIndex()
        let conversation = try persistence.loadConversation(id: id)!
        try persistence.deleteConversation(id: id)
        "\(index.conversationIDs[0] == id)|\(index.activeConversationID == id)|\(index.preferences.selectedModelID ?? "")|\(conversation.title)|\((try persistence.loadConversation(id: id)) == nil)"
        """#)
        XCTAssertEqual(loaded.value, "true|true|gpt|Erster Chat|true")
    }

    func testTargetUIKitSystemBackgroundLowersForBackgroundAndForeground() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let background = try await kernel.lowerViewExpression(
            "Text(\"Chat\").background(Color(uiColor: .systemBackground))"
        )
        XCTAssertEqual(background, .modified(
            content: .text("Chat"),
            modifier: .background(style: .color(.init(style: .systemBackground)), shape: nil)
        ))
        let foreground = try await kernel.lowerViewExpression(
            "Text(\"Chat\").foregroundStyle(Color(uiColor: .systemBackground))"
        )
        XCTAssertEqual(foreground, .modified(
            content: .text("Chat"),
            modifier: .foregroundStyle(.systemBackground)
        ))
    }

    func testTargetPersistenceCannotWriteOutsideItsWorkspace() async throws {
        let workspace = try makeWorkspace()
        let outside = workspace.rootURL.deletingLastPathComponent().appendingPathComponent("outside.json")
        let kernel = InterpreterKernel(workspace: workspace)
        let outsideDeclaration = "let outside = URL(fileURLWithPath: \(String(reflecting: outside.path)))"
        let resolved = try await kernel.evaluate("import Foundation\n" + outsideDeclaration + "\noutside.path")
        XCTAssertEqual(resolved.value, outside.path)
        do {
            _ = try await kernel.evaluate(#"""
            try Data("blocked".utf8).write(to: outside, options: .atomic)
            """#)
            XCTFail("Atomic write outside the project should be denied")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        }
    }

    func testClassLazyPropertyUsesCompletedSelfAndRunsOnlyOnce() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        final class Counter {
            var calls = 0
            lazy var value = self.compute()
            func compute() -> Int { calls += 1; return calls * 2 }
        }
        let counter = Counter()
        """)
        let before = try await kernel.evaluate("counter.calls")
        XCTAssertEqual(before.value, "0")
        let first = try await kernel.evaluate("counter.value")
        XCTAssertEqual(first.value, "2")
        let second = try await kernel.evaluate("counter.value")
        XCTAssertEqual(second.value, "2")
        let after = try await kernel.evaluate("counter.calls")
        XCTAssertEqual(after.value, "1")
    }

    func testCustomViewCallbackDoesNotReplaceMatchingEnumMember() throws {
        let source = """
        struct RootView: View {
            var body: some View {
                ActionView(cancel: { dismissAction() })
            }
        }
        struct ActionView: View {
            let cancel: () -> Void
            var body: some View {
                Button("Cancel", role: .cancel) { cancel() }
            }
        }
        """
        let expression = try ViewBodySourceEditor().extract(in: source, typeName: "RootView").expression
        let expanded = try CustomViewSourceExpander().expand(
            expression, from: source, rootTypeName: "RootView"
        )
        XCTAssertTrue(expanded.contains("role: .cancel"), expanded)
        XCTAssertTrue(expanded.contains("({ dismissAction() })()"), expanded)
    }

    func testOriginalNoticeBannerFixedSizeIsRendered() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        let view = try await kernel.lowerViewExpression(
            "Text(\"Notice\").fixedSize(horizontal: false, vertical: true)"
        )
        XCTAssertEqual(view, .modified(
            content: .text("Notice"),
            modifier: .fixedSize(horizontal: false, vertical: true)
        ))

        let retry = try await kernel.lowerViewExpression(
            "Button(\"Retry\") {}.buttonStyle(.borderless)"
        )
        guard case .modified(_, .buttonStyleBorderless) = retry else {
            return XCTFail("Expected the original retry button style")
        }

        let progress = try await kernel.lowerViewExpression(
            "ProgressView().controlSize(.small)"
        )
        guard case .modified(_, .controlSizeSmall) = progress else {
            return XCTFail("Expected the original streaming progress size")
        }
    }

    func testMessagePaddingFollowsCurrentInterpreterValue() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("var isUser = true")
        let source = "Text(\"Message\").padding(isUser ? 12 : 0)"
        let first = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(first, .modified(
            content: .text("Message"), modifier: .padding(edges: .all, length: 12)
        ))
        _ = try await kernel.evaluate("isUser = false")
        let second = try await kernel.lowerViewExpression(source)
        XCTAssertEqual(second, .modified(
            content: .text("Message"), modifier: .padding(edges: .all, length: 0)
        ))
    }

    func testUnmodifiedSwiftChatSourceReloadsThroughStoredFileLink() async throws {
        let sourceURL = try XCTUnwrap(Bundle.module.url(
            forResource: "SwiftChatApp_Step5(1)", withExtension: "swift"
        ))
        let original = try Data(contentsOf: sourceURL)
        let originalSource = try XCTUnwrap(String(data: original, encoding: .utf8))
        let entry = try AppEntryPointSourceExtractor().extract(from: originalSource)
        let extracted = try ViewBodySourceEditor().extract(
            in: originalSource, typeName: entry.rootViewTypeName
        )
        _ = try CustomViewSourceExpander().expand(
            extracted.expression, from: originalSource, rootTypeName: entry.rootViewTypeName
        )
        _ = try CustomViewSourceExpander().stateDeclarations(in: originalSource)
        let workspace = try makeWorkspace()
        let kernel = InterpreterKernel(workspace: workspace)
        let link = try await kernel.linkSourceFile(at: sourceURL)
        XCTAssertEqual(link.fileName, sourceURL.lastPathComponent)

        let first = try await kernel.reloadAndRunApp()
        XCTAssertEqual(Data(first.sourceSnapshot.source.utf8), original)
        XCTAssertEqual(first.entryPoint.appTypeName, "SwiftChatApp")

        let reopened = InterpreterKernel(workspace: workspace)
        let retainedLink = try await reopened.linkedSourceFile()
        XCTAssertEqual(retainedLink, link)
        let second = try await reopened.reloadAndRunApp()
        XCTAssertEqual(Data(second.sourceSnapshot.source.utf8), original)
        let linkAfterReload = try await reopened.linkedSourceFile()
        XCTAssertEqual(linkAfterReload, link)
    }

    func testSessionQueuesCancelDelayedWorkAndPreserveSerialOrder() async throws {
        let kernel = InterpreterKernel(workspace: try makeWorkspace())
        _ = try await kernel.evaluate("""
        import Foundation
        var events: [String] = []
        let queue = DispatchQueue(label: "login")
        let lock = NSLock()
        queue.async {
            lock.lock()
            defer { lock.unlock() }
            events.append("first")
            DispatchQueue.main.async { events.append("main") }
        }
        queue.async { events.append("second") }
        let cancelled = DispatchWorkItem { events.append("cancelled") }
        let polling = DispatchWorkItem { events.append("poll") }
        queue.asyncAfter(deadline: .now() + 0.04, execute: cancelled)
        queue.asyncAfter(deadline: .now() + 0.04, execute: polling)
        cancelled.cancel()
        """)
        var observedEvents = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            observedEvents = try await kernel.evaluate("events.joined(separator: \",\")").value
            if observedEvents.contains("poll") { break }
        }
        let queueFailures = await kernel.callbackFailures()
        XCTAssertTrue(queueFailures.isEmpty, queueFailures.joined(separator: "\n"))
        XCTAssertFalse(observedEvents.contains("cancelled"))
        let ordered = observedEvents.split(separator: ",")
        XCTAssertTrue((ordered.firstIndex(of: "first") ?? ordered.endIndex)
                      < (ordered.firstIndex(of: "second") ?? ordered.endIndex), observedEvents)
        XCTAssertTrue(observedEvents.contains("main"), observedEvents)
        XCTAssertTrue(observedEvents.contains("poll"), observedEvents)
    }

    func testReloadCancelsOldWorkAndAsyncPublishedRefreshesCurrentView() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftInterpreterAsyncApp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("AsyncApp.swift")
        let kernel = InterpreterKernel(workspace: try ProjectWorkspaceStore(
            rootURL: root.appendingPathComponent("Workspaces", isDirectory: true)
        ).workspace(for: ProjectID()))
        try Data("""
        import Foundation
        import SwiftUI
        final class Store: ObservableObject {
            @Published var title = "Fresh"
            func update() {
                DispatchQueue.main.async { self.title = "Updated" }
            }
            func delay() {
                let work = DispatchWorkItem { self.title = "Old" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            }
        }
        @main struct AsyncApp: App {
            var body: some Scene { WindowGroup { ContentView() } }
        }
        struct ContentView: View {
            @StateObject private var store = Store()
            var body: some View {
                VStack {
                    Text(store.title)
                    Button("Update") { store.update() }
                    Button("Delay") { store.delay() }
                }
            }
        }
        """.utf8).write(to: sourceURL)
        _ = try await kernel.linkSourceFile(at: sourceURL)
        let first = try await kernel.reloadAndRunApp()
        guard case .verticalStack(_, _, let children) = first.rootView,
              case .button(_, let update, _) = children[1],
              case .button(_, let delay, _) = children[2] else {
            return XCTFail("Expected the two controls")
        }
        _ = try await kernel.performAction(update)
        try await Task.sleep(for: .milliseconds(80))
        let updateFailures = await kernel.callbackFailures()
        XCTAssertTrue(updateFailures.isEmpty, updateFailures.joined(separator: "\n"))
        let updated = try await kernel.refreshAppView(first)
        XCTAssertEqual(textValues(in: updated.rootView).first, "Updated")
        guard case .verticalStack(_, _, let refreshedChildren) = updated.rootView,
              case .button(_, let refreshedDelay, _) = refreshedChildren[2] else {
            return XCTFail("Expected Delay after refresh")
        }
        _ = delay
        _ = try await kernel.performAction(refreshedDelay)
        let second = try await kernel.reloadAndRunApp()
        try await Task.sleep(for: .milliseconds(180))
        let fresh = try await kernel.refreshAppView(second)
        XCTAssertEqual(textValues(in: fresh.rootView).first, "Fresh")
    }

    func testSessionCompletionAndFragmentedSSECallbacks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Step34URLProtocol.self]
        let kernel = InterpreterKernel(workspace: try makeWorkspace(),
                                       keychainBackend: SystemProjectKeychainBackend(),
                                       networkSessionConfiguration: configuration)
        _ = try await kernel.evaluate("""
        import Foundation
        var models = ""
        var failure = ""
        let modelsRequest = URLRequest(url: URL(string: "https://chatgpt.com/models")!)
        URLSession.shared.dataTask(with: modelsRequest) { data, response, error in
            if let data = data { models = String(data: data, encoding: .utf8) ?? "decode" }
        }.resume()
        let failureRequest = URLRequest(url: URL(string: "https://auth.openai.com/failure")!)
        URLSession.shared.dataTask(with: failureRequest) { data, response, error in
            if error != nil { failure = "transport" }
        }.resume()
        final class Stream: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
            var text = ""
            var state = "waiting"
            var lineBuffer = Data()
            var task: URLSessionDataTask?
            func start(_ path: String) {
                let configuration = URLSessionConfiguration.default
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                task = session.dataTask(with: URLRequest(url: URL(string: "https://chatgpt.com/" + path)!))
                task?.resume()
            }
            func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                            didReceive response: URLResponse,
                            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
                completionHandler(.allow)
            }
            func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                lineBuffer.append(data)
                while let newline = lineBuffer.firstIndex(of: 10) {
                    let lineData = Data(lineBuffer[..<newline])
                    var normalized = lineData
                    if normalized.last == 13 { normalized.removeLast() }
                    let next = lineBuffer.index(after: newline)
                    lineBuffer.removeSubrange(lineBuffer.startIndex..<next)
                    if let line = String(data: normalized, encoding: .utf8), line.hasPrefix("data: ") {
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { state = "complete" }
                        else {
                            text += payload
                            if payload == "Stop" { task?.cancel(); state = "cancelled" }
                        }
                    }
                    if state == "cancelled" { return }
                }
            }
            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                if error != nil { state = "error" }
                else if state == "waiting" { state = "incomplete" }
                session.finishTasksAndInvalidate()
            }
            func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {}
        }
        let stream = Stream()
        stream.start("stream")
        let cancelledStream = Stream()
        cancelledStream.start("cancel")
        let failedStream = Stream()
        failedStream.start("failure")
        """)
        try await Task.sleep(for: .milliseconds(300))
        let networkFailures = await kernel.callbackFailures()
        XCTAssertTrue(networkFailures.isEmpty, networkFailures.joined(separator: "\n"))
        let result = try await kernel.evaluate(#"models + "|" + failure + "|" + stream.text + "|" + stream.state + "|" + cancelledStream.text + "|" + cancelledStream.state + "|" + failedStream.state"#)
        XCTAssertEqual(result.value, #"{"models":["gpt"]}|transport|Hello|complete|Stop|cancelled|error"#)
    }

    func testDeviceCodePollingTokenAndModelCallbacksStayInOrder() async throws {
        Step34URLProtocol.resetPolls()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Step34URLProtocol.self]
        let kernel = InterpreterKernel(workspace: try makeWorkspace(),
                                       keychainBackend: SystemProjectKeychainBackend(),
                                       networkSessionConfiguration: configuration)
        _ = try await kernel.evaluate("""
        import Foundation
        final class LoginFlow {
            let queue = DispatchQueue(label: "device-login")
            let session = URLSession(configuration: .ephemeral)
            var task: URLSessionDataTask?
            var pollWork: DispatchWorkItem?
            var events: [String] = []
            func start() { queue.async { self.requestCode() } }
            func send(_ path: String, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
                var request = URLRequest(url: URL(string: "https://auth.openai.com/" + path)!)
                request.httpMethod = "POST"
                request.httpBody = Data("client".utf8)
                task = session.dataTask(with: request) { data, response, error in
                    self.queue.async { completion(data, response, error) }
                }
                task?.resume()
            }
            func requestCode() {
                send("deviceauth/usercode") { data, response, error in
                    if error != nil || data == nil { self.events.append("error"); return }
                    self.events.append("code")
                    self.schedulePoll()
                }
            }
            func schedulePoll() {
                let work = DispatchWorkItem { [weak self] in self?.poll() }
                pollWork = work
                queue.asyncAfter(deadline: .now() + 0.02, execute: work)
            }
            func poll() {
                send("deviceauth/token") { data, response, error in
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 403 {
                        self.events.append("pending")
                        self.schedulePoll()
                    } else if status == 200 {
                        self.events.append("authorization")
                        self.exchange()
                    } else { self.events.append("error") }
                }
            }
            func exchange() {
                send("oauth/token") { data, response, error in
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 200 && data != nil && error == nil {
                        self.events.append("token")
                        self.loadModels()
                    } else { self.events.append("error") }
                }
            }
            func loadModels() {
                let request = URLRequest(url: URL(string: "https://chatgpt.com/models")!)
                URLSession.shared.dataTask(with: request) { data, response, error in
                    self.queue.async {
                        if data != nil && error == nil { self.events.append("models") }
                        else { self.events.append("error") }
                    }
                }.resume()
            }
        }
        let login = LoginFlow()
        login.start()
        """)
        try await Task.sleep(for: .milliseconds(450))
        let failures = await kernel.callbackFailures()
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let result = try await kernel.evaluate("login.events.joined(separator: \",\")")
        XCTAssertEqual(result.value, "code,pending,authorization,token,models")
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

private final class Step34URLProtocol: URLProtocol, @unchecked Sendable {
    private static let pollCounter = Step34PollCounter()
    static func resetPolls() { pollCounter.reset() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let poll = url.path == "/deviceauth/token" ? Self.pollCounter.next() : 0
        let status = poll == 1 ? 403 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunks: [String]
        switch url.path {
        case "/deviceauth/usercode": chunks = [#"{"device_auth_id":"id","user_code":"CODE"}"#]
        case "/deviceauth/token": chunks = [status == 403 ? #"{"error":"pending"}"# : #"{"authorization_code":"token"}"#]
        case "/oauth/token": chunks = [#"{"access_token":"access"}"#]
        case "/models": chunks = [#"{"models":["gpt"]}"#]
        case "/stream": chunks = ["data: He", "l\r", "\n\ndata: lo\n\ndata: [DONE]\n\n"]
        case "/cancel": chunks = ["data: Stop\n\n", "data: Later\n\n"]
        default: chunks = []
        }
        for chunk in chunks { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class Step34PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func reset() { lock.withLock { count = 0 } }
    func next() -> Int { lock.withLock { count += 1; return count } }
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
