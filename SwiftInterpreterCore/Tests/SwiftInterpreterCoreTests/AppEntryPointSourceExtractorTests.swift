import XCTest
@testable import SwiftInterpreterCore

final class AppEntryPointSourceExtractorTests: XCTestCase {
    func testFindsSwiftChatAppAndWindowGroupRootView() throws {
        let entryPoint = try AppEntryPointSourceExtractor().extract(from: """
        import SwiftUI

        struct ContentView: View {
            var body: some View { Text("Chat") }
        }

        @main
        struct SwiftChatApp: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """)

        XCTAssertEqual(
            entryPoint,
            InterpretedAppEntryPoint(appTypeName: "SwiftChatApp", rootViewTypeName: "ContentView")
        )
    }

    func testAcceptsQualifiedConformancesAndExplicitGetters() throws {
        let entryPoint = try AppEntryPointSourceExtractor().extract(from: """
        struct RootView: SwiftUI.View {
            var body: some SwiftUI.View { Text("Root") }
        }

        @main
        struct QualifiedApp: SwiftUI.App {
            var body: some SwiftUI.Scene {
                get { return SwiftUI.WindowGroup { RootView() } }
            }
        }
        """)

        XCTAssertEqual(entryPoint.appTypeName, "QualifiedApp")
        XCTAssertEqual(entryPoint.rootViewTypeName, "RootView")
    }

    func testReportsMissingAndAmbiguousMainApp() {
        assertExtractionError(
            in: "struct Demo { var body: some View { Text(\"x\") } }",
            equals: .noMainApp
        )

        assertExtractionError(
            in: """
            @main struct FirstApp: App { var body: some Scene { WindowGroup { FirstView() } } }
            struct FirstView: View { var body: some View { Text("1") } }
            @main struct SecondApp: App { var body: some Scene { WindowGroup { SecondView() } } }
            struct SecondView: View { var body: some View { Text("2") } }
            """,
            equals: .multipleMainApps
        )
    }

    func testRequiresAppConformanceAndOneComputedBodyProperty() {
        assertExtractionError(
            in: "@main struct Demo { var body: some Scene { WindowGroup { RootView() } } }\nstruct RootView: View {}",
            equals: .appMustConformToApp("Demo")
        )

        assertExtractionError(
            in: "@main struct Demo: App {}",
            equals: .bodyPropertyCount(typeName: "Demo", count: 0)
        )

        assertExtractionError(
            in: "@main struct Demo: App { var body: some Scene { WindowGroup { RootView() } }; var body: some Scene { WindowGroup { RootView() } } }\nstruct RootView: View {}",
            equals: .bodyPropertyCount(typeName: "Demo", count: 2)
        )
    }

    func testRequiresSupportedWindowGroupAndDirectRootInitializer() {
        let root = "struct RootView: View { var body: some View { Text(\"x\") } }"

        assertExtractionError(
            in: "@main struct Demo: App { var body: some Scene { EmptyScene() } }\n\(root)",
            equals: .unsupportedWindowGroup
        )

        assertExtractionError(
            in: "@main struct Demo: App { var body: some Scene { WindowGroup { makeRoot() } } }\n\(root)",
            equals: .unsupportedRootViewExpression
        )

        assertExtractionError(
            in: "@main struct Demo: App { var body: some Scene { WindowGroup { MissingView() } } }",
            equals: .rootViewTypeNotFound("MissingView")
        )
    }

    func testRequiresOneTopLevelRootStructConformingToView() {
        assertExtractionError(
            in: "@main struct Demo: App { var body: some Scene { WindowGroup { RootView() } } }\nstruct RootView {}",
            equals: .rootViewMustConformToView("RootView")
        )

        assertExtractionError(
            in: """
            @main struct Demo: App { var body: some Scene { WindowGroup { RootView() } } }
            struct RootView: View {}
            struct RootView: View {}
            """,
            equals: .multipleRootViewTypes("RootView")
        )
    }

    private func assertExtractionError(
        in source: String,
        equals expected: AppEntryPointExtractionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AppEntryPointSourceExtractor().extract(from: source),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? AppEntryPointExtractionError, expected, file: file, line: line)
        }
    }
}
