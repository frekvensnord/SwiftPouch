# Follow-up to the Step 33 checkup

Branch: `after_step_33_checkup_fix`, copied from `after_step_33_checkup`
at `a54bb50cd537f2163fda449a1171ab6240455c5c`. The source checkup and
all earlier branches remain unchanged.

## Implemented in the app-preview path

- `reloadAndRunApp()` now evaluates top-level model and service declarations
  before lowering the root view. It excludes native `View` and `App` types
  from this bootstrap, preserving the host-owned UI lifecycle and the
  intentional whole-source preflight boundary.
- Root `@StateObject` declarations receive stable interpreter names. A
  zero-argument root initializer may use local `let` values and
  `StateObject(wrappedValue:)` assignments, so multiple owned objects can
  share the same instance. A refresh keeps them; a reload recreates them.
  Child `@ObservedObject` inputs resolve to the passed object, and supported
  child `@State` cells are seeded by their own view type.
- `@Published` stored class properties are adapted to interpreted property
  observers. Their mutations notify an `AsyncStream`; the host coalesces
  notifications and refreshes its current view. Notifications from a discarded
  interpreter generation are ignored. Class methods can assign implicit enum
  cases to explicitly typed properties.
- Referenced `@ViewBuilder` computed properties expand into their builder
  content. Builder `switch` cases become interpreted `if case` branches;
  associated-value bindings stay in scope for dynamic text and actions.

The targeted regression loads an `@main` app with a shared session/store
object graph, `@ObservedObject` child inputs, child state, a conditional
builder helper, and an associated-value switch helper. It checks the initial
snapshot, a `@Published` update from a button action, notification delivery,
the refreshed snapshot, and fresh objects after reload. Existing failed-reload
rollback coverage remains in the core suite.

## Acceptance boundary

This is a focused app-preview integration fix. The root initializer subset is
explicit; unsupported initializer statements fail instead of being skipped.
The complete Clasp/SwiftChat prototype is still a source-exact acceptance
target for Step 35. Step 34 must supply ordered GCD and URLSession callbacks,
streaming, and cancellation; other target-specific view constructs may need
additional support. `reloadAndRun()` retains its complete-source preflight.
An unsigned iOS SDK build and macOS unit tests do not replace the physical
iPhone run.

## Verification

GitHub Actions [run #84](https://github.com/frekvensnord/SwiftPouch/actions/runs/37210598393)
on commit `63db11bb3c52cf0a6e0f6db37e6c2a156a74a2b1` passed all 123 core
tests and built the unsigned host for the iOS 27 device SDK with Xcode 27.
