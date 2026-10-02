#if canImport(SwiftUI) && canImport(UniformTypeIdentifiers)
import Foundation
import SwiftUI

/// A host-app panel that reopens one project's workspace and exposes its
/// persistent source-file controls.
///
/// The host supplies a stable `ProjectID` and a stable app-owned workspace
/// root. Reusing both values recreates the same workspace and restores the
/// linked Swift file after the host app restarts.
@available(iOS 16.0, macOS 13.0, *)
@MainActor
public struct InterpreterProjectHostPanel: View {
    private let projectID: ProjectID
    private let workspacesRootURL: URL

    @State private var kernel: InterpreterKernel?
    @State private var errorMessage: String?
    @State private var isOpeningWorkspace = false
    @State private var workspaceRequestID = UUID()

    public init(projectID: ProjectID, workspacesRootURL: URL) {
        self.projectID = projectID
        self.workspacesRootURL = workspacesRootURL
    }

    public var body: some View {
        Group {
            if let kernel {
                InterpreterSourceFileControls(kernel: kernel)
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .foregroundColor(.red)
                    Button("Erneut versuchen") {
                        Task { await openWorkspaceIfNeeded() }
                    }
                }
            } else {
                ProgressView("Interpreter-Projekt wird geöffnet …")
            }
        }
        .onAppear {
            Task { await openWorkspaceIfNeeded() }
        }
        .onChange(of: projectID) { _ in
            workspaceRequestID = UUID()
            kernel = nil
            errorMessage = nil
            isOpeningWorkspace = false
            Task { await openWorkspaceIfNeeded() }
        }
    }

    private func openWorkspaceIfNeeded() async {
        guard kernel == nil, !isOpeningWorkspace else { return }
        let requestID = UUID()
        workspaceRequestID = requestID
        isOpeningWorkspace = true
        errorMessage = nil
        defer {
            if workspaceRequestID == requestID {
                isOpeningWorkspace = false
            }
        }

        let projectID = self.projectID
        let workspacesRootURL = self.workspacesRootURL
        let store = ProjectWorkspaceStore(rootURL: workspacesRootURL)

        do {
            let workspace = try await Task.detached(priority: .utility) {
                try store.workspace(for: projectID)
            }.value
            guard workspaceRequestID == requestID, self.projectID == projectID else { return }
            kernel = InterpreterKernel(workspace: workspace)
        } catch {
            guard workspaceRequestID == requestID, self.projectID == projectID else { return }
            errorMessage = error.localizedDescription
        }
    }
}
#endif
