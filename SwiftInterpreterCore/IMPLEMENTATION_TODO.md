# Remaining implementation checklist

This is the active implementation plan for the iPhone 13 / iOS 27 target.
The current development branch is built incrementally from the Step 28.2
checkpoint; `main` remains the last fully green baseline.

## Step 26 — Validate iOS 27 and freeze the dependency baseline

The actual target is an iPhone 13 running iOS 27. The host and package currently
have an iOS 26 minimum deployment target, which is retained while validating
the app on iOS 27. The developer workflow uses GitHub Actions, so package
resolution, tests, and the host build run on a GitHub-hosted macOS runner; no
local Mac is required. SwiftScript is vendored from the fixed upstream commit
`d298d01`; ShellKit and SwiftSyntax use fixed revisions.

1. Add a GitHub Actions workflow using a GitHub-hosted macOS runner. Select
   Xcode 27, its iOS 27 SDK, and Swift 6.4 explicitly, and log the selected
   versions so a runner-image update cannot silently change the toolchain.
2. Run dependency resolution, core tests, and the iOS host build on the GitHub
   Actions macOS runner using the selected Xcode/Swift toolchain. Resolve and
   record the SwiftScript, ShellKit, SwiftSyntax, and transitive revisions.
   Keep Swift tools version 6.3 and host Swift language mode 6.0 for the first
   build; change either only if CI reports a concrete incompatibility.
3. Verify SwiftSyntax 603.0.2 against Xcode 27's Swift 6.4 compiler.
4. Commit both resolved package graphs and rerun GitHub Actions from the
   frozen graph. SwiftScript is vendored with narrow interpreter fixes;
   ShellKit is fixed at `40c1b41`, and SwiftSyntax at 603.0.2.
5. Use the CI-produced host build for a smoke test on the iPhone 13 running
   iOS 27: open a `.swift` file from Files/iCloud Drive, retain its link, and
   reload edited contents with Reload & Run. Any required signing or
   distribution is handled through the CI build path; no local Mac is needed.

**Execution status:** Run #15 passed 72/72 core tests and built the unsigned
iOS host with Xcode 27.0, Swift 6.4, and the iOS 27.0 SDK. Both resolved graphs
are committed; CI verifies them on every push. Installing the
artifact and trying Files/iCloud Reload & Run on an iPhone 13 remains a device
smoke test; it requires signing and access to the device.

**Done when:** GitHub Actions passes dependency resolution, core tests, and the
iOS host build with Xcode 27/Swift 6.4 from the committed dependency graph.
The physical-device reload smoke test is tracked separately from this CI gate.

## Step 27 — Implement `@State` and `@Binding`

Replace the former String/Bool snapshot defaults with persistent mutable
interpreter cells. Give each cell a deterministic identity derived from its
owning view type and property, so same-named properties in different view
types remain independent across body refreshes. Rewrite reads, writes, and
projected references to the owning cell. Expand a simple custom-view
`@Binding var value: T` passed directly as `$state`, so child reads and writes
use the exact parent cell. Preserve projected child bindings when a custom
view forwards them to another custom view. Keep native input rendering for
the controls step.

The current supported initializer subset is a plain String or Bool literal.
The binding subset is one typed stored `@Binding` property receiving a direct
`$identifier` projection during custom-view expansion. A child may forward its
projected binding to another custom view, preserving the original state cell.
State owned by nested or dynamically repeated view instances, nonliteral
defaults, and native `Binding` controls remain outside this step.

**Done when:** repeated body lowering preserves a cell's current value,
same-named state in different view types is isolated, a binding-backed child
can both read and write its parent's cell, a subsequent body lowering shows
that write, and interpreter reset restores each literal default.

## Step 28 — Provide environment and host context

- **28.1 complete:** maps host `scenePhase` into interpreted view bodies.
- **28.2 complete:** routes direct interpreted `dismiss()` calls to the native
  presentation environment.

`@StateObject`, `@ObservedObject`, and `@Published` remain an explicit carry-over
before the unchanged target app can source live lists from `ChatStore` and
`CodexSessionManager`. Do not mistake collection lowering in Step 29.1 for that
object-observation bridge.

## Step 29 — Evaluate dynamic lists and scroll views

### Step 29.1 — `ForEach` identity and dynamic collections

Expand the currently available Array, Set, or integer-range values into
identified runtime rows. Support `Identifiable.id` and explicit simple
`id:` key paths, preserve each row's lexical item value for dynamic content and
button actions, and rebuild from the latest interpreter values after refresh.

**Done when:** stable identities survive reordering, duplicate IDs and
unsupported collection/ID forms fail clearly, and updated collection contents
produce an updated row tree without reparsing or reselecting the data source.

### Step 29.2 — Scrolling and lazy-list containers

Implemented: `ScrollView`, `LazyVStack`, and `ScrollViewReader` lower into
portable nodes rendered by their native SwiftUI counterparts. `.id(value)`
uses the same type-tagged identity as `ForEach` rows. Direct `proxy.scrollTo`
calls in interpreted button actions carry reader, target, and optional anchor
to the host after the view refresh; the matching native reader performs the
scroll. Collection changes rebuild lazy rows with their existing stable IDs.

The target chat's `proxy.scrollTo` calls occur inside `.onChange`, whose event
callbacks belong to Step 31. Live `ChatStore`/`CodexSessionManager` observation
also remains an explicit prerequisite for target-sourced rows; Step 29.2
provides their scroll containers and proxy route.

## Step 30 — Add inputs and controls

Support the target's actual forms of `TextField`, `Picker`, `Menu`, `Form`,
`Button` closures, and dynamic view values.

**Done when:** composing, model and reasoning selection, and settings are
operable, with edits flowing back into app state through bindings.

**Step 30 implementation:** The renderer and interpreter now connect native
`TextField` (including vertical input and submit), `Picker`, `Menu`, `Form`,
`Section`, dynamic labels and tags, and supported Button callbacks. Direct
`$state` and forwarded `@Binding` String projections write to the same
interpreter cell. A `Binding(get:set:)` picker reads its current String and
executes its setter when the native selection changes. Composer edits are
collected briefly, and a button action flushes pending edits before it runs.
The core tests exercise composing and submit, dynamic model menu actions,
reasoning choices, form lowering, and state refresh. The unchanged full target
file still depends on the deferred observable-object bridge and the later
navigation, event, Foundation, and service steps; this control slice does not
claim that the entire target app can already run.

The Step 30 follow-up also resolves the target's zero-argument named
`sendDraft`-style callback, pure computed control values, and simple immutable
`let` aliases within a view builder. Dynamic system-image names and the
composer button's conditional background style follow current interpreter
values, while the settings loading indicator renders as `ProgressView()`.
These are tested through standalone control compositions; evaluating the
unchanged `ContentView` remains gated by the separately tracked object-state
bridge and Step 31+ view and service features.

## Step 31 — Add navigation, presentations, and view events

Implement `NavigationStack`, toolbar components, sheets including item-based
sheets, alerts, `.onAppear`, and `.onChange`.

**Done when:** history, settings, device-code dialogs, and notifications can be
opened, updated, and dismissed from the target app.

The interpreted view subset now lowers `NavigationStack`, the target's toolbar
placements, title modifiers, Boolean and item sheets, alerts, medium detents,
visible drag indicators, `.onAppear`, and `.onChange`. The native host writes
presentation dismissal back to the interpreted binding, and event closures
execute in the existing state scope. The target's object-backed store and
session properties remain dependent on their separate observable-object and
service bridges in the later milestones.

## Step 32 — Add Foundation, file-system, and UIKit bridges

Provide the required forms of `URL`, `Data`, `Date`, `UUID`, JSON coding,
`JSONSerialization`, `FileManager`, and String helpers. Scope file operations
to the current interpreter project. Map the used UIKit system background color.

**Done when:** conversation and settings data can be read and written in the
interpreter project's workspace.

## Step 33 — Add project-scoped Security and Keychain access

Implement the required Keychain constants and narrow host bridges for
`SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, and `SecItemDelete`.

**Done when:** sign-in and stored credentials work through the intended
Keychain calls and are isolated to the correct project context.

## Step 34 — Connect GCD and URLSession streaming

First coordinate the required queue, work-item, and lock behavior with the
serial runtime. Then implement `URLSession`, requests, callbacks, and the
delegate proxy for server-sent events.

**Done when:** sign-in, model loading, response streaming, and cancellation
remain ordered and cooperate correctly with the UI.

## Step 35 — Accept the unchanged target app end to end

Reload the original `.swift` file through its existing file link and verify
the complete UI, chat, history, settings, Keychain sign-in, streaming,
cancellation, and restoration flows. Run and record the full build and test
results against the frozen dependency graph from Step 26. Confirm Reload & Run
still reads the same linked file without another picker selection.

**Done when:** the agreed flows pass on the selected iOS target and the build,
tests, toolchain, and dependency revisions are documented and reproducible.
