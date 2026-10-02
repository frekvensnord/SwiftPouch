import XCTest
@testable import SwiftInterpreterCore

final class SourceAnalysisTests: XCTestCase {
    func testClassifiesTargetAppModulesAndSwiftUIRequirements() {
        let source = """
        import SwiftUI
        import Foundation
        import Security
        import UIKit

        @main
        struct DemoApp: App {
            var body: some Scene {
                WindowGroup { DemoView() }
            }
        }

        struct DemoView: View {
            @State private var count = 0

            @ViewBuilder
            var body: some View {
                Text("\\(count)")
            }
        }
        """

        let analysis = SourceAnalyzer().analyze(source, fileName: "Demo.swift")

        XCTAssertEqual(analysis.importedModules, ["SwiftUI", "Foundation", "Security", "UIKit"])
        XCTAssertEqual(
            Set(analysis.detectedFeatures),
            Set([.appEntryPoint, .propertyWrappers, .resultBuilders])
        )
        XCTAssertFalse(analysis.isReadyForEvaluation)
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .moduleCustomRuntimeRequired })
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .moduleHostBridgeRequired })
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .unsupportedPropertyWrapper })
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .unsupportedResultBuilder })
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .hostManagedEntryPoint })
        XCTAssertTrue(analysis.diagnostics.allSatisfy { diagnostic in
            guard let location = diagnostic.location else { return true }
            return location.line > 0 && location.column > 0
        })
    }

    func testLiteralStringAndBoolStateDefaultsAreReportedAsPartialSupport() {
        let analysis = SourceAnalyzer().analyze("""
        import SwiftUI
        struct DemoView: View {
            @State private var title = "Ready"
            @State private var isVisible = false
            var body: some View { Text(title) }
        }
        """)

        let partialStateDiagnostics = analysis.diagnostics.filter {
            $0.code == .partiallySupportedPropertyWrapper
        }
        XCTAssertEqual(partialStateDiagnostics.count, 2)
        XCTAssertTrue(partialStateDiagnostics.allSatisfy { $0.severity == .warning })
        XCTAssertFalse(analysis.diagnostics.contains { $0.code == .unsupportedPropertyWrapper })
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .moduleCustomRuntimeRequired })
        XCTAssertFalse(analysis.isReadyForEvaluation)
    }

    func testPartialStateWarningStillBlocksWholeSourceEvaluation() {
        let analysis = SourceAnalyzer().analyze("""
        struct DemoView {
            @State private var title = "Ready"
        }
        """)

        XCTAssertFalse(analysis.isReadyForEvaluation)
        let error = SourcePreflightError(analysis: analysis)
        XCTAssertTrue(error.localizedDescription.contains("plain String or Bool literal"))
    }

    func testUnsupportedStateDefaultRemainsAnError() {
        let analysis = SourceAnalyzer().analyze("""
        struct DemoView {
            @State private var count = 0
        }
        """)

        XCTAssertFalse(analysis.isReadyForEvaluation)
        XCTAssertTrue(analysis.diagnostics.contains { diagnostic in
            diagnostic.code == .unsupportedPropertyWrapper
                && diagnostic.severity == .error
                && diagnostic.message.contains("outside that subset")
        })
    }

    func testOtherSwiftUIPropertyWrappersRemainErrors() {
        let analysis = SourceAnalyzer().analyze("""
        struct DemoView {
            @StateObject var model: Model
            @ObservedObject var observed: Model
            @Binding var title: String
            @Published var count = 0
            @Environment(\\.colorScheme) var colorScheme
        }
        """)

        let wrapperErrors = analysis.diagnostics.filter {
            $0.code == .unsupportedPropertyWrapper
        }
        XCTAssertEqual(wrapperErrors.count, 4)
        XCTAssertTrue(wrapperErrors.allSatisfy { $0.severity == .error })
        let bindingDiagnostics = analysis.diagnostics.filter {
            $0.code == .partiallySupportedPropertyWrapper
        }
        XCTAssertEqual(bindingDiagnostics.count, 1)
        XCTAssertTrue(bindingDiagnostics[0].message.contains("writable alias"))
        XCTAssertFalse(analysis.isReadyForEvaluation)
    }

    func testScenePhaseAndDismissEnvironmentArePartiallySupported() {
        let analysis = SourceAnalyzer().analyze("""
        import SwiftUI
        struct DemoView: View {
            @Environment(\\.scenePhase) private var scenePhase
            @Environment(\\.dismiss) private var dismiss
            @Environment(\\.colorScheme) private var colorScheme
            var body: some View { Text("Ready") }
        }
        """)

        let partialEnvironmentDiagnostics = analysis.diagnostics.filter {
            $0.code == .partiallySupportedPropertyWrapper
        }
        XCTAssertEqual(partialEnvironmentDiagnostics.count, 2)
        XCTAssertTrue(partialEnvironmentDiagnostics.contains {
            $0.message.contains("scenePhase") && $0.message.contains("dismiss")
        })

        let unsupportedEnvironmentDiagnostics = analysis.diagnostics.filter {
            $0.code == .unsupportedPropertyWrapper
        }
        XCTAssertEqual(unsupportedEnvironmentDiagnostics.count, 1)
        XCTAssertTrue(unsupportedEnvironmentDiagnostics[0].message.contains("Environment"))
        XCTAssertFalse(analysis.isReadyForEvaluation)
    }

    func testBindingWithoutSimpleStoredValueShapeRemainsUnsupported() {
        let analysis = SourceAnalyzer().analyze("""
        struct ChildView {
            @Binding var title: String = "local"
        }
        """)

        XCTAssertTrue(analysis.diagnostics.contains {
            $0.code == .unsupportedPropertyWrapper && $0.message.contains("@Binding")
        })
        XCTAssertFalse(analysis.isReadyForEvaluation)
    }

    func testBuiltInModulePassesAndRepeatedImportIsDeduplicated() {
        let analysis = SourceAnalyzer().analyze("""
        import Foundation
        import Foundation
        let value = 4
        """)

        XCTAssertEqual(analysis.importedModules, ["Foundation"])
        XCTAssertTrue(analysis.isReadyForEvaluation)
        XCTAssertTrue(analysis.diagnostics.isEmpty)
    }

    func testUnknownModuleProducesLocationAwareError() {
        let analysis = SourceAnalyzer().analyze("\nimport UnavailableModule\n")

        XCTAssertFalse(analysis.isReadyForEvaluation)
        XCTAssertEqual(analysis.importedModules, ["UnavailableModule"])
        XCTAssertEqual(analysis.diagnostics.first?.code, .unregisteredModule)
        XCTAssertEqual(analysis.diagnostics.first?.location?.line, 2)
    }

    func testMalformedSourceProducesParserDiagnostic() {
        let analysis = SourceAnalyzer().analyze("struct Broken {")

        XCTAssertFalse(analysis.isReadyForEvaluation)
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .malformedSyntax })
    }

    func testModuleRegistryRejectsDuplicateRegistrations() throws {
        var registry = InterpreterModuleRegistry()
        let registration = ModuleRegistration(
            name: "Example",
            integration: .hostBridgeRequired,
            summary: "Example bridge."
        )
        try registry.register(registration)

        XCTAssertThrowsError(try registry.register(registration)) { error in
            XCTAssertEqual(error as? ModuleRegistryError, .duplicateName("Example"))
        }
    }
}
