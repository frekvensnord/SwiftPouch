# SwiftInterpreterCore — Schritt 25.3 (Zwischenstand)

Swift Package wrapper around the embedded SwiftScript interpreter.

The remaining implementation checklist is maintained in
[`IMPLEMENTATION_TODO.md`](IMPLEMENTATION_TODO.md). Step 26 now verifies and
freezes a known-working dependency graph before the remaining runtime work.

## Implemented

### Step 1 — Interpreter kernel

`InterpreterKernel` owns one `SwiftScriptInterpreter.Interpreter`, evaluates
source asynchronously, and supports resetting the in-memory interpreter.

### Step 2 — Project workspace and sandboxed evaluation

- `ProjectID` gives a project a stable UUID-based directory name. The target
  chat app can reuse each persisted conversation UUID as its project ID.
- `ProjectWorkspaceStore` creates or reopens one directory per ID.
- Each `InterpreterKernel` is bound to one workspace. Every evaluation binds a
  ShellKit `Shell` task-locally with the workspace as its sandbox root, a
  synthetic host identity, and `HOME`/`PWD` set to the project directory.
- Standard output is captured in `EvaluationResult`. Networking has no
  allow-listed hosts in this first project context.
- Evaluation, reset, and source-link operations are serialized because the
  interpreter retains mutable scope and the project owns one active source link.

### Step 3 — Source preflight and module inventory

- `SourceAnalyzer` parses source with SwiftParser and reports imported modules,
  malformed syntax, and the SwiftUI-specific constructs needed by the app.
- `InterpreterModuleRegistry` records whether a module is already supplied by
  SwiftScript or still needs a host bridge or custom runtime.
- The target app's imports are inventoried: `Foundation` is available from
  SwiftScript; `SwiftUI`, `Security`, and `UIKit` are reported as pending
  runtime integrations.
- Property wrappers and result builders produce source-located errors. The
  native `@main` declaration is reported as a host-managed entry point.
- `InterpreterKernel.evaluate` runs the preflight and returns structured
  diagnostics before unsupported source reaches the evaluator.

### Step 4 — Portable view tree and native renderer

- `RuntimeViewNode` is the first portable output contract for interpreted UI:
  text, images, vertical/horizontal stacks, buttons, spacers, and dividers.
- Button nodes carry stable `RuntimeActionID` values. The host receives taps via
  a callback, so interpreter closures do not leak into the renderer model.
- The kernel now registers the matching source closure and can execute a
  button's action ID in the active interpreter session.
- On platforms with SwiftUI, `SwiftUIRuntimeRenderer` maps the portable tree to
  native SwiftUI views. The node model remains usable without SwiftUI.
- The target app's view vocabulary is larger; this step establishes the tree
  and renderer boundary. State wrappers, the remaining modifier set,
  collections, and navigation/presentation nodes remain subsequent runtime work.

### Step 5 — Durable project source link and Reload & Run

- `InterpreterKernel.linkSourceFile(at:)` persists a bookmark for a selected
  `.swift` file in app-owned interpreter metadata, outside the script sandbox.
- `linkedSourceFile()` exposes the linked filename and link time;
  `unlinkSourceFile()` removes the reference while leaving the source file intact.
- iOS uses ordinary file bookmarks; macOS uses security-scoped bookmarks.
- `reloadAndRun()` resolves the bookmark, reads the current file through
  `NSFileCoordinator` on Apple platforms, refreshes stale bookmarks, runs
  preflight, and evaluates the snapshot in a fresh interpreter scope.
- File linking, status, unlinking, reload, evaluation, and reset are serialized
  by the kernel. The focused test checks that a second reload sees edited source
  and can redeclare its globals.

### Step 6 — Interpreter-host source controls

- On Apple platforms, `InterpreterSourceFileControls(kernel:)` provides a
  single-selection Swift file picker, linked-file status, unlink action, and
  Reload & Run button for the interpreter host screen.
- Selecting a file links it to the kernel; Reload & Run reads that same link on
  every press and displays the supported interpreted app view or an error
  (the app-rendering path is connected in Step 24).
- A custom host layout can create the kernel from its persisted `ProjectID` and
  app-owned workspace root, then embed `InterpreterSourceFileControls` directly.

### Step 7 — Host project panel

- `InterpreterProjectHostPanel(projectID:workspacesRootURL:)` reopens the
  project's workspace, creates its kernel, and presents the source controls.
- The host passes its persisted project or conversation UUID as `ProjectID` and
  a stable app-owned workspace root. Reopening the panel restores the same
  bookmark and sandbox workspace.
- This panel belongs to the interpreter host UI. It remains outside the
  interpreted SwiftChat project's view tree.

The host screen can embed it with:

```swift
InterpreterProjectHostPanel(
    projectID: ProjectID(conversationID),
    workspacesRootURL: interpreterProjectsDirectory
)
```

`conversationID` and `interpreterProjectsDirectory` must remain stable across
host launches for the linked source and workspace to reopen.

### Step 8 — Static SwiftUI expression lowering

- `SwiftUIViewExpressionLowerer` converts one static SwiftUI expression into a
  `RuntimeViewNode` tree. `InterpreterKernel.lowerViewExpression(_:)` exposes
  the lowering entry point to the host.
- The initial subset supports literal `Text`, `Image(systemName:)`, nested
  `VStack` and `HStack`, `Spacer`, and `Divider`. Stack alignment and spacing
  must be static literals.
- At this checkpoint, dynamic values, view modifiers, buttons, conditional or
  loop content, extra closures, and unsupported view types fail explicitly.
- This is an expression-level bridge only. It does not yet translate the
  target app's `body` declarations or connect state and actions to the renderer;
  the complete SwiftChat source therefore remains blocked by preflight.
- Tests cover a nested static tree and representative unsupported constructs.

### Step 9 — Static view modifier chains

- `RuntimeViewNode.modified(content:modifier:)` stores each modifier as an
  ordered wrapper, preserving the source chain's application order.
- The renderer applies static padding, fixed or maximum frame dimensions,
  alignment, foreground style, font, line limit, multiline text alignment,
  accessibility label, and disabled state.
- The lowerer recognizes common font text styles and system sizes with static
  weight and design, semantic colors including `Color(uiColor: .systemBackground)`,
  edge-specific padding, and closed line-limit ranges.
- At that checkpoint, modifier arguments had to be static and belong to the
  implemented subset. Backgrounds, overlays, sheets, and event handlers were
  still unsupported.
- Tests cover nested modifier order, Codable round-tripping, static font/color
  forms, and rejection of dynamic or unsupported modifiers.

### Step 10 — Static colors, backgrounds, and shapes

- The portable tree now represents `Color` values with static opacity,
  `Rectangle`, `Circle`, `Capsule`, and `RoundedRectangle` shapes, plus filled
  and stroked shapes.
- Static `.background(color)` and `.background(style, in: shape)` are lowered
  and rendered, including `Color(uiColor: .systemBackground)`, semantic colors,
  `Color.clear`, `.opacity(...)`, and the standard SwiftUI material styles.
- `RoundedRectangle` accepts a static nonnegative corner radius and the
  `.circular` or `.continuous` corner style. `.fill(Color)` and
  `.stroke(Color, lineWidth:)` require static colors and width.
- Conditional colors, the trailing-closure form of `.background`,
  `.contentShape`, `.overlay`, and other dynamic or unimplemented modifiers
  continue to return lowering errors. This is still expression-level support;
  it does not translate the target app's `body`, state, actions, or controls.
- Focused tests cover Color opacity, shaped color/material backgrounds, shape
  fill/stroke, Codable round-tripping, and rejection of dynamic backgrounds.

### Step 11 — Static overlays and hit-test shapes

- The ordered modifier tree now includes `.overlay(alignment:overlay:)` and
  `.contentShape(shape)`. The renderer applies native SwiftUI overlay alignment
  and content-shape behavior.
- `.overlay { ... }` and `.overlay(alignment: ...) { ... }` accept one static
  view expression. This covers the target's rounded-rectangle stroke overlay;
  `.contentShape(Rectangle())` covers the composer attachment button's hit area.
- Conditional overlay bodies, multiple sibling expressions, and dynamic shape
  values still fail explicitly. The target's conditional `ProgressView` overlay
  therefore awaits conditional-expression and dynamic-value support.
- Tests cover aligned and default static overlays, a stroked shape overlay,
  content shapes, and rejection of conditional or multi-expression overlays.

### Step 12 — Literal conditional view branches

- View-builder closures now lower `if` / `else if` / `else` expressions whose
  conditions are the boolean literals `true` or `false`.
- The lowerer checks both selected and unselected branches, then folds the
  static condition to the corresponding portable node. An `if` without an
  `else` lowers to `EmptyView` when its condition is false.
- Multiple sibling expressions in a selected branch or overlay are preserved
  as a renderer-independent `group`; stack builders continue to expose their
  direct children to the stack renderer.
- Dynamic conditions, optional bindings, and values read from app state still
  require the later interpreter-value and state bridge. Conditional branches
  with unsupported contents are rejected even when that branch is inactive.
- Tests cover static true/false branches, nested `else if`, empty
  branches, grouped siblings, overlays, and Codable round-tripping.

### Step 13 — Interpreter-scoped dynamic `Text` snapshots

- `InterpreterKernel.lowerViewExpression(_:)` now reads dynamic `Text(...)`
  arguments from the current SwiftScript interpreter scope. It serializes
  lowering with evaluation and reset, evaluates each distinct expression in
  the project Shell context, and uses its displayed value as the rendered text.
- Literal `Text` values remain handled by the pure lowerer. The kernel first
  validates the view structure with placeholders, so unsupported surrounding
  views fail before dynamic expressions execute.
- Each lowering call produces a snapshot: lowering again after an ordinary
  `evaluate(_:)` observes updated interpreter values. This does not yet make
  the rendered tree reactive to app state changes on its own.
- At this checkpoint, dynamic `Text` values inside conditional branches were
  rejected until branch-local condition evaluation was implemented in step 14.
  Other dynamic arguments, property-wrapper state, and body declarations
  remain subsequent work.
- Tests cover reading and refreshing a scoped string, string interpolation,
  and unchanged static lowering.

### Step 14 — Interpreter-backed Boolean view conditions

- `InterpreterKernel.lowerViewExpression(_:)` now evaluates expression-form
  `if` conditions in the current interpreter scope and selects nested branches
  from the resulting Boolean values. Re-lowering after an ordinary evaluation
  observes updated condition values.
- Before evaluating any condition or text value, the kernel lowers a
  placeholder version of the complete conditional tree. Both branches remain
  subject to structural validation, including the inactive branch.
- Conditions are then resolved from the outside inward. The source editor
  replaces each conditional with a `Group` for its selected statements, so
  conditions and dynamic `Text` values in inactive branches are never
  evaluated. Selected dynamic `Text` values continue to use the step-13
  snapshot behavior.
- `Group` and `EmptyView` now lower to the portable group and empty nodes.
  Boolean expression conditions are supported; optional-binding conditions
  such as `if let`, state wrappers, reactive updates, and dynamic modifier
  arguments remain subsequent work.
- Tests cover scope-driven condition changes, nested branch selection,
  non-Boolean condition errors, inactive-branch laziness, inactive-branch
  structural validation, and group/empty nodes.

### Step 15 — Interpreter-backed Boolean `.disabled` snapshots

- `.disabled(expression)` now accepts a dynamic Boolean expression when views
  are lowered through `InterpreterKernel.lowerViewExpression(_:)`. The
  expression is evaluated in the current project interpreter scope and stored
  in the portable modifier node as a snapshot.
- Re-lowering after an ordinary `evaluate(_:)` observes updated values, such as
  a changed `canSend` flag. The direct, scope-free lowerer still accepts only
  literal Boolean arguments.
- Both branches are structurally validated before selection. Dynamic
  `.disabled` expressions are evaluated only in the selected branch, and a
  non-Boolean result produces a lowering error.
- This step covers the target app's `.disabled(!canSend)` pattern without
  claiming reactive rendering. Optional-binding conditions, state wrappers,
  `body` declaration lowering, dynamic colors and dimensions, and native module
  bridges remain future work.
- Tests cover scope updates, inactive-branch laziness, non-Boolean rejection,
  and the scope-free lowerer's static-only boundary.

### Step 16 — Interpreter-backed optional-binding branches

- View conditions now accept simple identifier `let` bindings such as
  `if let conversation = maybeConversation` and comma-separated conditions
  following a binding. The complete condition is evaluated in the interpreter,
  preserving short-circuit behavior.
- A selected true branch carries its bound names into dynamic `Text` and
  `.disabled` snapshots. Binding scope is tracked per source region, so values
  remain available to nested branches and do not leak into sibling branches.
- Both branches are structurally lowered before condition evaluation. Values
  and conditions in inactive branches are skipped after branch selection.
- Tuple or enum patterns, `var` bindings, other non-expression condition
  clauses, property-wrapper state, and automatic reactive updates remain
  unsupported. This is expression-level support; it does not yet lower the
  target app's enclosing `body` declarations or custom views.
- Tests cover present and nil values, changing optionals, bound values used by
  following Boolean conditions, sibling-scope isolation, a bound
  `.disabled` argument, and lazy inactive branches.

### Step 17 — Named struct body extraction

- `InterpreterKernel.lowerViewBody(in:typeName:)` now finds the requested
  top-level struct, extracts its computed `body` getter, and sends the result
  through the existing interpreter-backed view lowerer. Dynamic values,
  conditions, optional bindings, and `.disabled` snapshots therefore follow
  the same scope and branch rules as direct expression lowering.
- A single expression and an explicit getter returning one expression are
  supported. Multiple view expressions are wrapped as a `Group`; missing,
  stored, duplicate, or ambiguous body declarations produce a lowering error.
- This is the first declaration-level bridge. It does not yet instantiate
  custom view types, resolve property wrappers, or evaluate local declarations
  and arbitrary control flow inside `body`.
- Tests cover selecting one named type from a source file, refreshing a body
  from interpreter scope, explicit getter returns, multiple sibling views,
  and unsupported body declarations.

### Step 18 — Literal `@State` initialization

- The named body extractor now reads simple stored `@State` properties with
  plain String or Bool literal initializers and seeds matching mutable
  variables into the kernel's interpreter scope on the first body lowering.
- Later lowerings preserve interpreter changes to those variables; reset
  and reload start a fresh interpreter scope and seed the source defaults
  again. This gives the existing condition and Text snapshot path access
  to basic view state.
- This is session-scoped snapshot support. It does not yet provide
  per-view-instance state, duplicate State names across different view types,
  automatic reactive rendering, or initialization
  for StateObject, ObservedObject, Binding, or Environment wrappers.
- Tests cover String and Bool defaults, changed values across lowerings,
  resetting to defaults, rejecting computed state initializers, and detecting
  state-name collisions between view types.

### Step 19 — Simple custom view composition

- `lowerViewBody(in:typeName:)` now expands references to top-level custom
  `View` structs before lowering their content. It supports synthesized
  memberwise calls whose inputs are labeled, immutable, unwrapped stored
  `let` properties without default values. Inputs are substituted as Swift
  expressions, so literals and values from the current interpreter scope both
  flow into the child body.
- Expansion is recursive for nested custom views, detects cycles and duplicate
  type declarations, and reports unsupported initializers explicitly. The
  existing state seeding and dynamic condition/Text snapshot path still runs
  after expansion, so a child view can use values passed from the root view's
  interpreter scope.
- This does not model explicit initializers, defaulted or mutable inputs,
  property wrappers on child views, closures, local computed helper properties,
  nested type declarations, or arbitrary `body` statements. Direct
  `lowerViewExpression(_:)` remains expression-only because it has no source
  file from which to resolve custom type declarations.
- Tests cover nested custom views, static and state-backed arguments, and
  diagnostics for unsupported inputs and recursive composition.

### Step 20 — Button actions in the interpreter session

- The view lowerer now accepts buttons with a static String title or a
  view-builder label, a closure action, and an optional `.cancel` or
  `.destructive` role. It stores the action as source under a `RuntimeActionID`
  in the lowered result; the portable node still carries only that ID.
- `InterpreterKernel.performAction(_:)` executes a registered action inside
  the existing project interpreter scope, so assignments and `print` output
  flow through the same session as body snapshots. Action code is kept out of
  view-conditional and dynamic-Text scanning, allowing ordinary `if` statements
  inside an action closure. The host can pass renderer callbacks to this API
  and lower the body again to refresh the resulting snapshot.
- Each successful lowering registers the action IDs belonging to that view
  tree. Reset and a successful Reload & Run clear them, and IDs from an earlier
  tree return an unknown-action error. Function-valued action references,
  dynamic String button titles, and framework calls that are absent from the
  interpreter scope remain unsupported.
- Tests cover title and label syntax, action output, state mutation,
  conditionals inside actions, roles, and action invalidation after reset.

### Step 21 — Target app compatibility baseline

- The unchanged target file is inventoried in
  [`TARGET_COMPATIBILITY.md`](TARGET_COMPATIBILITY.md). The matrix names its
  actual language constructs, property wrappers, SwiftUI views and modifiers,
  persistence calls, Keychain calls, networking APIs, and concurrency APIs,
  then maps each group to the current interpreter coverage and follow-up step.
- The package and host minimum deployment targets remain iOS 26; the actual
  runtime target is iPhone 13 with iOS 27. The package retains macOS 13 for its
  portable runtime and development surface, and declares Swift tools 6.3.
- Static review of Steps 1–25 found no host API that requires an OS newer than
  the declared iOS 26 minimum. Existing native host views are guarded for iOS 16 or
  later. Xcode 27 supplies the Swift 6.4 compiler; the host project's
  `SWIFT_VERSION = 6.0` is its language-mode setting. Step 26 verifies these
  settings and the complete file-reload workflow on the actual device and OS.
- This step records compatibility and aligns the package deployment target;
  it does not mark unsupported runtime capabilities as available. The source
  preflight still blocks the full target file until the bridges and runtime
  features in the compatibility matrix are implemented.
- The current environment has no `swift` executable, so package tests and an
  Apple-platform build could not be run during this step.

### Step 22 — Capability-aware source preflight

- `SourceAnalyzer` now recognizes the exact `@State` initializer subset that
  Step 18 can seed: mutable identifier properties initialized with plain String
  or Bool literals. Those declarations produce source-located partial-support
  warnings instead of unsupported-wrapper errors. The warnings still block
  whole-file evaluation because Reload & Run does not yet run the view-snapshot
  path. Other `@State` forms and `@StateObject`, `@ObservedObject`, `@Binding`,
  `@Published`, and unsupported `@Environment` keys remain blocking errors.
- Explicit `@ViewBuilder` declarations remain errors because the full-source
  evaluation path does not run those declaration bodies. The diagnostic now
  distinguishes them from the selected builder expressions supported by the
  expression lowerer.
- Module errors remain blocking. In particular, `SwiftUI` reports that selected
  expressions can become view snapshots while module symbols and complete
  app rendering are still unavailable. Security and UIKit diagnostics include
  their registered bridge summaries.
- Tests cover partial literal-state classification, unsupported state
  initializers, other wrapper blockers, and the fact that partial support does
  not make whole-file evaluation ready.
- The source test suite could not be executed here because `swift` is absent.

### Step 23 — App entry and root-view discovery

- `AppEntryPointSourceExtractor` locates the single top-level `@main` struct,
  checks that it conforms to `App`, follows its computed body to one direct
  `WindowGroup` closure, and reads the no-argument root-view initializer.
- The root must be a unique top-level struct conforming to `View`. Qualified
  `SwiftUI.App` / `SwiftUI.View` conformances, an explicit `get` accessor, and
  an explicit `return` from the app body's getter are supported. Other
  app-body shapes produce a specific localized extraction error.
- `InterpreterKernel.resolveAppEntryPoint(in:)` exposes the discovered app and
  root type names to the host. This is discovery only: it does not execute the
  app declaration, lower the root body, or change Reload & Run's evaluation
  behavior. Wiring the discovered root into the host renderer is Step 24.
- Focused tests cover the SwiftChat entry shape, qualified conformances, body
  and root validation, and the kernel API. XCTest could not be run here because
  this environment has no `swift` executable.

### Step 24 — Linked app preview and renderer integration

- `SwiftInterpreterHost/SwiftInterpreterHost.xcodeproj` is now a minimal native
  iOS host target. Its root view embeds `InterpreterProjectHostPanel`, retains
  one `ProjectID` in `UserDefaults`, and stores workspaces in Application
  Support. The Xcode project references the adjacent core package locally.
- `InterpreterKernel.reloadAndRunApp()` rereads the linked file, resolves its
  `@main` / `WindowGroup` root, starts a fresh interpreter scope, and lowers
  that root body into an `InterpretedAppViewSnapshot`.
- The host screen's Reload & Run button now calls this app path and passes the
  portable root tree to `SwiftUIRuntimeRenderer`. Button actions run in the
  active interpreter session and rebuild the same source snapshot, preserving
  its current simple `@State` values. Reload invalidates the old action table.
- `reloadAndRun()` remains the whole-source script-evaluation API. App preview
  lowering reads the source file and interprets only supported root-view
  expressions; it does not yet execute every app declaration or use the
  complete-source module preflight.
- The real SwiftChat root begins with `NavigationStack`, which is not in the
  current portable view tree; nested helper inputs and the rest of its view
  graph also exceed the current subset. Step 24 connects the launch and display
  path for supported views; the target's remaining views, helpers, state
  objects, and bridges follow in the later compatibility steps.
- A focused reload test checks fresh state from edited disk contents, action
  invalidation, and action-driven view refresh. XCTest could not be run here
  because this environment has no `swift` executable.

### Step 25.1 — Model declarations and Codable

- The target's model layer uses raw-value enums, associated-value enums,
  structs, a class implementing a protocol, protocol-typed values, and user
  type extensions. The embedded SwiftScript interpreter already evaluates
  these declarations, so the host does not duplicate their type semantics.
- Focused `InterpreterKernel` integration tests now exercise SwiftChat-shaped
  `ChatMessage`, `ChatConversation`, `ChatPreferences`, `ChatIndex`, and
  `ModelDefinition` declarations. The Codable probe encodes and decodes nested
  conversations and indexes containing `UUID`, `Date`, optionals, arrays, and
  raw-value enums, and checks synthesized `Equatable`, default initializers,
  and a computed extension property.
- Separate probes cover associated-value enum matching, class method dispatch
  through a protocol-typed value, and protocol conformance added in an
  extension.
- The scope here is limited to declaration and model semantics. The analyzer
  still does not provide static type or protocol-witness checking. `Result`,
  error propagation, `inout`, keypaths, and closure/capture semantics stay in
  25.2; remaining target-specific gaps belong in 25.3. Whole-file SwiftChat
  execution remains blocked by its pending SwiftUI, Security, and UIKit
  integrations and property-wrapper/result-builder runtime work.
- The regression tests were added but could not be executed here because this
  environment has no `swift` executable or Apple toolchain.

### Step 25.2 — Results, errors, inout, key paths, and closures

- Four additional `InterpreterKernel` probes now cover the language forms
  used by the target's async service code: `Result` success/failure matching,
  thrown enum errors, `do`/`catch`, `try?`, and `LocalizedError` messages;
  mutation through an `inout` optional; the `map(\.id)` and `map(\.self)`
  key-path forms; and escaping callbacks with a `[weak self]` capture.
- The `inout` probe exercises Swift argument semantics without calling
  `SecItemCopyMatching`; its Security bridge and `CFDictionary` conversion stay
  in the later host-bridge step. The closure probe checks that a weakly
  captured owner can be released while the callback remains callable.
- SwiftScript documents `Result`, error propagation, `inout`, closures, and
  key paths in its supported language subset. This step checks their concrete
  SwiftChat forms through the host kernel, including `[weak self]` capture.
- The package tests could not be run here because the environment has no Swift
  toolchain. The probes are included in the project as executable regression
  coverage for the next Apple-toolchain run.
- Step 25.3 remains responsible for checking the complete SwiftChat source for
  any other missing interpreter semantics and adding only those targeted gaps.

### Step 25.3 — Remaining SwiftChat language-pattern audit

- The final 25.x audit checked the remaining language forms used by
  `accountFields`, `CodexAPI.models(from:)`, `tokenClaims`, and the stream
  operation: casts from `[String: Any]`, named tuple returns, optional
  fallbacks, `compactMap` with guarded early returns, `for ... where`,
  `while`/`while let`, `defer`, `if case` matching, and the
  `Result<Void, Error>.success(())` completion shape.
- A focused host-kernel probe now combines those exact shapes. It checks
  nested dynamic dictionary casts and rejection of invalid model rows, account
  tuple fields, Base64 padding, ordered lock cleanup, enum state matching, and
  a `Void` result completion.
- The audit found no additional host-side language evaluator to add: these
  constructs belong to the embedded interpreter. The remaining SwiftChat
  blockers are framework and app-runtime work recorded in the compatibility
  matrix, including Security, UIKit, SwiftUI views/state, and delegate bridges.
- The complete-source path was not run here because the Apple/Swift toolchain
  is unavailable and the listed host bridges are still pending. The new probe
  is included in the package for execution with the next Swift toolchain run.

## Dependencies

- `SwiftScriptInterpreter` and `SwiftScriptAST` from `../Vendor/SwiftScript`
  (upstream commit `d298d01`, with the targeted runtime changes documented there)
- `ShellKit` at revision `40c1b417e6c6318d2ca644d9a3062dc6befd0e31`
- `SwiftParser` and `SwiftSyntax` from swift-syntax 603.0.2

The package declares iOS 26 and macOS 13 as minimum deployment targets and
uses Swift tools 6.3. The actual device target is iPhone 13 running iOS 27;
Step 26 uses Xcode 27.0, the iOS 27.0 SDK, and Swift 6.4. Both the core package
and host project commit their resolved graphs. Run #15 passed 72 core tests
and built the unsigned iOS host. The iPhone 13/iOS 27 installation and reload
smoke test remains a separate device check. Step 36 rechecks reproducibility.

## Build and test

Step 26 runs `swift test` and builds the iOS host in GitHub Actions on a
GitHub-hosted macOS runner with the selected Xcode 27 / Swift 6.4 toolchain.

Whole-source evaluation remains blocked by preflight until expression lowering
is integrated with richer dynamic values and property-wrapper state, module
bridging, remaining presentation modifiers, and the broader SwiftUI component
vocabulary. The app-preview path now resolves and renders only the root-view
subset represented by `RuntimeViewNode`; SwiftChat's `NavigationStack` and
remaining app-specific APIs are still upcoming. Step 17 extracts a named
top-level struct's computed body, Step 18 seeds literal String and Bool `@State` defaults for body
snapshots, and Step 19 expands simple custom views that use synthesized
memberwise inputs. Step 20 routes closure-backed Button actions into the active
interpreter scope. Step 27 replaces snapshot-only state defaults with mutable
interpreter cells keyed by owning view type and property. It rewrites state
references consistently across a body and its action closures, and expands a
direct `$state` projection into a custom view's `@Binding` property as a
writable alias to the same cell. A child `@Binding` projection is retained
when passed onward to another custom view. The supported initializers remain
plain String and Bool literals; native controls, nested state-owning views,
and dynamic repeated-view identity are later work. `@StateObject`,
`@ObservedObject` and `@Published` remain later bridges. Step 28.1 routes the
host's scene phase into interpreted bodies. Step 28.2 rewrites direct
`@Environment(\.dismiss)` calls in interpreted actions into host-dismissal
requests; `SwiftUIRuntimeRenderer` invokes the `DismissAction` from its own
native SwiftUI environment after the action completes. Other environment keys
and dismissal aliases are unsupported. Native sheet rendering is still a
later step, where the target app's individual presentation flows can be tested
end to end. Partial wrappers continue to block whole-source preflight even
though the app-view path can lower their supported subset.
Whole-source preflight still blocks these app-view wrappers because it does
not run the specialized body-lowering path. Step 16 handles simple identifier
let bindings in view-expression snapshots. Step 15 handles dynamic Boolean
`.disabled` snapshots; other modifier parameters are not implemented yet.
