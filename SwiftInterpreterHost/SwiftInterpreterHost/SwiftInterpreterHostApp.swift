import Foundation
import SwiftInterpreterCore
import SwiftUI

@MainActor
@main
struct SwiftInterpreterHostApp: App {
    var body: some Scene {
        WindowGroup {
            InterpreterHostRootView()
        }
    }
}

@MainActor
private struct InterpreterHostRootView: View {
    @State private var projectID: ProjectID

    init() {
        let key = "swiftInterpreterHost.projectID"
        let storedValue = UserDefaults.standard.string(forKey: key)
        let rawProjectID: UUID
        if let storedValue, let savedID = UUID(uuidString: storedValue) {
            rawProjectID = savedID
        } else {
            rawProjectID = UUID()
        }
        UserDefaults.standard.set(rawProjectID.uuidString, forKey: key)
        _projectID = State(initialValue: ProjectID(rawProjectID))
    }

    private var workspacesRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftInterpreterProjects", isDirectory: true)
    }

    var body: some View {
        NavigationStack {
            InterpreterProjectHostPanel(
                projectID: projectID,
                workspacesRootURL: workspacesRootURL
            )
            .navigationTitle("Swift Interpreter")
        }
    }
}
