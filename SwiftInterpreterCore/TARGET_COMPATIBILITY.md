# SwiftChat target compatibility baseline

This is the implementation baseline from Step 21, updated for the Step 22
capability-aware preflight, Step 23 app-entry discovery, and Step 24 app-view
pipeline. It records what the unchanged target file uses and what the
interpreter currently covers. The matrix guides Steps 25–36; a row becomes
supported only when its runtime implementation and focused tests are present.

## Reference inputs

| Input | Value |
|---|---|
| Target source | `upload/SwiftChatApp_Step5(1).swift` |
| Source line count | 2,111 |
| SHA-256 | `774870ae19e3825ab75e4fa8411d3e563b8ba631acab4cccde4d493caf134490` |
| Interpreter package | `SwiftInterpreterCore` |
| Swift package tools version | 6.3 |
| iOS package deployment target | 26.0 |
| macOS package deployment target | 13.0 |
| Target device and runtime OS | iPhone 13, iOS 27 |
| Target build SDK and compiler | Xcode 27, iOS 27 SDK, Swift 6.4 |

The file path and hash identify the source version inventoried here. If the
target file changes, refresh this matrix against the new source before treating
the compatibility list as current.

## Target feature matrix

| Area | Constructs used by the target | Current coverage and remaining work |
|---|---|---|
| App entry and launch | `@main SwiftChatApp: App`, `WindowGroup`, `ContentView()` | Step 24's `reloadAndRunApp()` rereads the linked file, resolves the root, resets the interpreter, lowers the root body, and displays supported nodes through `SwiftUIRuntimeRenderer`. SwiftChat uses `NavigationStack` and nested helper inputs outside the current view/expansion subset, so the target cannot render yet. The separate `reloadAndRun()` API retains whole-source evaluation and its preflight. |
| Swift model and control-flow language | `Codable`, `Identifiable`, `Equatable`, `LocalizedError`, structs, classes, associated-value enums, protocols, extensions, optionals, arrays, dictionaries, `Result`, `throws`/`try`, `guard`, `if let`, `switch`, casts, closures, keypaths, `inout`, weak captures | Step 25.1 adds focused kernel probes for target-shaped model declarations, Codable round-trips, enum cases, class/protocol dispatch, and extension conformance. Step 25.2 probes `Result`, thrown/caught errors, `try?`, `LocalizedError`, `inout`, target keypaths, escaping callbacks, and `[weak self]`. Step 25.3 adds a target-shaped audit for `[String: Any]` casts, named tuples, optional fallbacks, guarded `compactMap`, `for ... where`, `while`/`while let`, `defer`, `if case`, and `Result<Void, Error>.success(())`. SwiftScript provides these interpreter semantics; protocol dispatch is dynamic without static witness checking. The actual Security `inout` call still awaits its scoped host bridge. `SourceAnalyzer` does not statically resolve types or API calls, and the complete SwiftChat file remains blocked by its host bridges and SwiftUI runtime. |
| Property-wrapper state | `@StateObject`, `@State`, `@ObservedObject`, `@Binding`, `@Published`, `@Environment(\.scenePhase)`, `@Environment(\.dismiss)` | Step 24's app-view path seeds simple String/Bool `@State` defaults and refreshes a snapshot after actions. These remain snapshot values without per-view identity or projected bindings. Other `@State` initializers, `@StateObject`, `@ObservedObject`, `@Binding`, `@Published`, and `@Environment` still need bridges and observable lifetimes in Steps 27–29; whole-source preflight still blocks them. |
| Explicit result builders | `@ViewBuilder` on `conversationBody` and `authSummary`; builder closures in the view declarations | Button labels and selected static builder expressions can be lowered. Explicit `@ViewBuilder` declarations still block full-source evaluation. The app-view path expands referenced view bodies only through the current body editor and expression lowerer; helper properties, dynamic builder statements, `switch`, and local declarations remain unsupported. Continue dynamic builder and body execution alongside Steps 27–32. |
| Current portable views | `Text`, `Image`, `VStack`, `HStack`, `Spacer`, `Divider`, `Group`, `EmptyView`, supported shapes, and closure-backed `Button` | Static forms are available; dynamic `Text`, selected conditions, simple custom-view expansion, and action routing are snapshot-based. Custom initializers, closure-valued view inputs, and arbitrary helper properties remain unsupported. |
| Additional target views and data views | `NavigationStack`, `ScrollViewReader`, `ScrollView`, `LazyVStack`, `ForEach`, `List`, `Menu`, `Section`, `Form`, `TextField`, `Picker`, `Label`, `Link`, `ProgressView`, `ToolbarItem`, `ToolbarItemGroup` | These views, collection identity, scrolling, and input behavior are not represented by the current portable tree. Add them in Steps 30–32, alongside navigation, presentation, and event support. |
| Target modifiers and events | `.toolbar`, `.sheet`, `.alert`, `.onAppear`, `.onChange`, `.onSubmit`, `.swipeActions`, `.navigationTitle`, `.navigationBarTitleDisplayMode`, `.presentationDetents`, `.presentationDragIndicator`, `.listStyle`, `.textInputAutocapitalization`, `.autocorrectionDisabled`, `.submitLabel`, `.textSelection`, `.buttonStyle`, `.controlSize`, plus padding, frame, font, color, background, overlay, and disabled patterns | A bounded static subset is implemented for padding, frame, font, foreground style, line limit, text alignment, accessibility label, disabled snapshots, backgrounds, overlays, and hit-test shapes. Sheets, alerts, navigation, lifecycle callbacks, the remaining modifiers, and dynamic modifier arguments are open. Steps 30–32 address them. |
| Foundation persistence | `URL`, `UUID`, `Date`, `Data`, `JSONEncoder`, `JSONDecoder`, `JSONSerialization`, `FileManager`, atomic writes, directory creation, file reads/deletes, formatting and string helpers | Foundation is registered as interpreter-provided. That registration does not redirect `FileManager` into the project workspace or prove the target's full Foundation API surface. Implement and test the required file/JSON bridge in Step 33. |
| Security and UIKit | `Security` Keychain constants and `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`; `CFDictionary` conversion and inout result; `Color(uiColor: .systemBackground)` | `Security` and `UIKit` are registered as required host bridges and still block preflight. A narrow system-background color form is recognized by the view lowerer, but the UIKit import bridge is not complete. Implement the scoped Keychain bridge in Step 34 and the required UIKit value mapping in Step 33. |
| Networking and streaming | `URLSession`, `URLRequest`, `URLResponse`, `HTTPURLResponse`, data tasks, `URLSessionDataDelegate`, `URLSessionTaskDelegate`, synchronous response disposition, incremental SSE parsing, cancellation | No interpreted URLSession bridge or delegate proxy exists. The project Shell has no allowed network hosts. Implement ordered host callbacks and stream/cancellation behavior in Step 35. |
| GCD and synchronization | Serial `DispatchQueue`, `DispatchQueue.main.async`, `DispatchWorkItem` scheduling/cancellation, `NSLock` | No runtime services bridge these APIs yet. Implement ordered queue, work-item, and lock behavior before the URLSession callback bridge in Step 35. |
| Preflight and app-preview result | Imports `SwiftUI`, `Foundation`, `Security`, `UIKit`; the wrappers and explicit builders listed above | Whole-source `reloadAndRun()` still blocks on SwiftUI, Security, UIKit, unsupported wrappers, and explicit `@ViewBuilder` declarations; Foundation is accepted and literal String/Bool `@State` remains partial support. `reloadAndRunApp()` bypasses full-source evaluation and lowers only the root snapshot; the target still uses unsupported navigation and view constructs. |

## Build baseline

`Package.swift` declares iOS 26 and macOS 13, with Swift tools 6.3. The target
device is an iPhone 13 running iOS 27; CI uses a GitHub-hosted macOS runner
with Xcode 27 / Swift 6.4. SwiftScript is vendored from `d298d01` with focused
runtime fixes; ShellKit is pinned to `40c1b41`, SwiftSyntax to 603.0.2, and
both package graphs have `Package.resolved`. Run #15 passed all 72 XCTest cases
and the unsigned device-SDK host build under Xcode 27.0 / Swift 6.4 / iOS SDK
27.0. The host project's `SWIFT_VERSION = 6.0` remains its language-mode
setting. A signed installation and Files/iCloud Reload & Run smoke test on the
iPhone 13 still require the physical device and a signing path.
The iOS 26 minimum deployment target remains valid for running on iOS 27. The
test files remain under `Tests/SwiftInterpreterCoreTests`.
