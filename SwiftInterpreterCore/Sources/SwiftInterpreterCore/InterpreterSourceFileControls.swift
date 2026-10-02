#if canImport(SwiftUI) && canImport(UniformTypeIdentifiers)
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// File-linking controls for the interpreter host app.
///
/// Embed this view in the host app's interpreter screen. Its picker opens one
/// Swift source file and stores the link through `InterpreterKernel`; Reload &
/// Run reads that linked file and renders its supported root-view snapshot.
/// This view is not part of the interpreted project's runtime view tree.
@available(iOS 16.0, macOS 13.0, *)
@MainActor
public struct InterpreterSourceFileControls: View {
    private let kernel: InterpreterKernel

    @Environment(\.scenePhase) private var hostScenePhase
    @State private var linkedFile: ProjectSourceFileReference?
    @State private var appViewSnapshot: InterpretedAppViewSnapshot?
    @State private var errorMessage: String?
    @State private var isFileImporterPresented = false
    @State private var isWorking = false
    @State private var pendingScenePhase: RuntimeScenePhase?

    public init(kernel: InterpreterKernel) {
        self.kernel = kernel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Swift-Datei öffnen…") {
                    isFileImporterPresented = true
                }
                .disabled(isWorking)

                Button("Reload & Run") {
                    Task { await reloadAndRun() }
                }
                .disabled(linkedFile == nil || isWorking)
            }

            if let linkedFile {
                HStack {
                    Label(linkedFile.fileName, systemImage: "doc.text")
                    Spacer()
                    Button("Verknüpfung lösen") {
                        Task { await unlinkFile() }
                    }
                    .disabled(isWorking)
                }
                .accessibilityElement(children: .contain)
            } else {
                Text("Keine Swift-Datei verknüpft.")
                    .foregroundColor(.secondary)
            }

            if isWorking {
                ProgressView("Interpreter läuft …")
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
            }

            if let appViewSnapshot {
                VStack(alignment: .leading, spacing: 8) {
                    Text("App: \(appViewSnapshot.entryPoint.appTypeName)")
                        .font(.headline)
                    SwiftUIRuntimeRenderer(
                        node: appViewSnapshot.rootView,
                        onActionWithDismissal: { actionID in
                            await performAction(actionID, in: appViewSnapshot)
                        }
                    )
                    .disabled(isWorking)
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.swiftSource],
            allowsMultipleSelection: false,
            onCompletion: handleFileImporterResult
        )
        .onAppear {
            Task { await refreshLinkedFile() }
        }
        .onChange(of: hostScenePhase) { newPhase in
            pendingScenePhase = Self.runtimeScenePhase(for: newPhase)
            Task { await refreshPendingScenePhaseIfPossible() }
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await linkFile(at: url) }
        case .failure(let error):
            guard (error as NSError).code != NSUserCancelledError else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func linkFile(at url: URL) async {
        // Keep the picker-granted scope active while the kernel serializes and
        // persists the bookmark. The store balances its own nested access.
        let acquiredScope = url.startAccessingSecurityScopedResource()
        defer {
            if acquiredScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        isWorking = true
        errorMessage = nil
        appViewSnapshot = nil

        do {
            linkedFile = try await kernel.linkSourceFile(at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
        await refreshPendingScenePhaseIfPossible()
    }

    private func refreshLinkedFile() async {
        do {
            linkedFile = try await kernel.linkedSourceFile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadAndRun() async {
        isWorking = true
        errorMessage = nil
        appViewSnapshot = nil
        pendingScenePhase = nil

        do {
            appViewSnapshot = try await kernel.reloadAndRunApp(
                scenePhase: Self.runtimeScenePhase(for: hostScenePhase)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
        await refreshPendingScenePhaseIfPossible()
    }

    private func performAction(
        _ actionID: RuntimeActionID,
        in snapshot: InterpretedAppViewSnapshot
    ) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        errorMessage = nil

        var requestsHostDismissal = false
        do {
            let result = try await kernel.performAction(actionID)
            appViewSnapshot = try await kernel.refreshAppView(
                snapshot,
                scenePhase: Self.runtimeScenePhase(for: hostScenePhase)
            )
            requestsHostDismissal = result.requestsHostDismissal
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
        await refreshPendingScenePhaseIfPossible()
        return requestsHostDismissal
    }

    private func unlinkFile() async {
        isWorking = true
        errorMessage = nil
        appViewSnapshot = nil

        do {
            try await kernel.unlinkSourceFile()
            linkedFile = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
        await refreshPendingScenePhaseIfPossible()
    }

    private func refreshPendingScenePhaseIfPossible() async {
        while !isWorking,
              let requestedPhase = pendingScenePhase,
              let snapshot = appViewSnapshot {
            pendingScenePhase = nil
            guard snapshot.scenePhase != requestedPhase else { continue }

            isWorking = true
            do {
                appViewSnapshot = try await kernel.refreshAppView(
                    snapshot,
                    scenePhase: requestedPhase
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private static func runtimeScenePhase(for scenePhase: ScenePhase) -> RuntimeScenePhase {
        switch scenePhase {
        case .active:
            return .active
        case .inactive:
            return .inactive
        case .background:
            return .background
        @unknown default:
            return .inactive
        }
    }
}
#endif
