# Remaining implementation checklist

This is the active plan after Step 25.3. Step 26 freezes a verified dependency
baseline before the remaining runtime features are added, so each later step
can build against the same tested interpreter and package APIs.

## Step 26 — Validate iOS 27 and freeze the dependency baseline

The actual target is an iPhone 13 running iOS 27. The host and package currently
have an iOS 26 minimum deployment target, which is retained while validating
the app on iOS 27. The developer workflow uses GitHub Actions, so package
resolution, tests, and the host build run on a GitHub-hosted macOS runner; no
local Mac is required. SwiftScript and ShellKit currently follow their `main`
branches; establish a working graph there, then pin it before Step 27.

1. Add a GitHub Actions workflow using a GitHub-hosted macOS runner. Select
   Xcode 27, its iOS 27 SDK, and Swift 6.4 explicitly, and log the selected
   versions so a runner-image update cannot silently change the toolchain.
2. Run dependency resolution, core tests, and the iOS host build on the GitHub
   Actions macOS runner using the selected Xcode/Swift toolchain. Resolve and
   record the SwiftScript, ShellKit, SwiftSyntax, and transitive revisions.
   Keep Swift tools version 6.3 and host Swift language mode 6.0 for the first
   build; change either only if CI reports a concrete incompatibility.
3. Verify that the SwiftSyntax release works with Xcode 27's Swift 6.4
   compiler. The current `603.0.0+` requirement follows the Swift 6.3 line, so
   retain it only if it builds and passes tests; otherwise select a compatible
   stable release and a compatible SwiftScript revision.
4. Pin the passing SwiftScript and ShellKit revisions, lock the compatible
   SwiftSyntax release and transitive graph, and record Xcode, Swift, iOS SDK,
   and dependency revisions. Rerun the GitHub Actions workflow from that
   frozen graph.
5. Use the CI-produced host build for a smoke test on the iPhone 13 running
   iOS 27: open a `.swift` file from Files/iCloud Drive, retain its link, and
   reload edited contents with Reload & Run. Any required signing or
   distribution is handled through the CI build path; no local Mac is needed.

**Execution status:** The workflow is prepared at
`.github/workflows/interpreter-ios27.yml`. Its first run, verification of the
603 SwiftSyntax line against Swift 6.4, dependency locking, and the device
smoke test are still pending. This workspace has no Git remote and no
connected GitHub repository, so the workflow cannot be dispatched from this
session. Keep Step 27 blocked until the workflow has passed and its resolved
dependency graph has been committed as `Package.resolved`.

**Done when:** GitHub Actions passes dependency resolution, core tests, and the
iOS host build with Xcode 27/Swift 6.4; the CI-produced build passes the linked-
file reload smoke test on the iPhone 13 running iOS 27; and the dependency
graph is pinned and reproducible.

## Step 27 — Implement `@State` and `@Binding`

Replace the current String/Bool snapshot initialization with mutable state
cells that have stable view identity. Connect bindings to readable and
writable state, including projected values such as `$draft`.

**Done when:** user input and actions read and mutate the same state values
used by the next view rebuild.

## Step 28 — Connect observable objects and published changes

Implement object lifetime, property access, and change notifications for
`@StateObject`, `@ObservedObject`, and `@Published`.

**Done when:** changes in `ChatStore` or `CodexSessionManager` trigger another
view evaluation, and each object survives for the appropriate host lifetime.

## Step 29 — Provide environment and host context

Connect the target's `scenePhase` and `dismiss` environment values to the host.

**Done when:** scene changes and dismissal of a presented view have the same
effect in interpreted code as in the native host environment.

## Step 30 — Evaluate dynamic lists and scroll views

Add `ForEach` with stable IDs, dynamic collections, `ScrollView`, `LazyVStack`,
and `ScrollViewReader` with its scroll proxy.

**Done when:** message, history, model, and reasoning lists build from current
app data and update when that data changes.

## Step 31 — Add inputs and controls

Support the target's actual forms of `TextField`, `Picker`, `Menu`, `Form`,
`Button` closures, and dynamic view values.

**Done when:** composing, model and reasoning selection, and settings are
operable, with edits flowing back into app state through bindings.

## Step 32 — Add navigation, presentations, and view events

Implement `NavigationStack`, toolbar components, sheets including item-based
sheets, alerts, `.onAppear`, and `.onChange`.

**Done when:** history, settings, device-code dialogs, and notifications can be
opened, updated, and dismissed from the target app.

## Step 33 — Add Foundation, file-system, and UIKit bridges

Provide the required forms of `URL`, `Data`, `Date`, `UUID`, JSON coding,
`JSONSerialization`, `FileManager`, and String helpers. Scope file operations
to the current interpreter project. Map the used UIKit system background color.

**Done when:** conversation and settings data can be read and written in the
interpreter project's workspace.

## Step 34 — Add project-scoped Security and Keychain access

Implement the required Keychain constants and narrow host bridges for
`SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, and `SecItemDelete`.

**Done when:** sign-in and stored credentials work through the intended
Keychain calls and are isolated to the correct project context.

## Step 35 — Connect GCD and URLSession streaming

First coordinate the required queue, work-item, and lock behavior with the
serial runtime. Then implement `URLSession`, requests, callbacks, and the
delegate proxy for server-sent events.

**Done when:** sign-in, model loading, response streaming, and cancellation
remain ordered and cooperate correctly with the UI.

## Step 36 — Accept the unchanged target app end to end

Reload the original `.swift` file through its existing file link and verify
the complete UI, chat, history, settings, Keychain sign-in, streaming,
cancellation, and restoration flows. Run and record the full build and test
results against the frozen dependency graph from Step 26. Confirm Reload & Run
still reads the same linked file without another picker selection.

**Done when:** the agreed flows pass on the selected iOS target and the build,
tests, toolchain, and dependency revisions are documented and reproducible.
