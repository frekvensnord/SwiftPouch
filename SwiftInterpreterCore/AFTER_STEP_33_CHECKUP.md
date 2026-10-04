# Checkup after Step 33

Base: `fd5a6b7578ee5580a33def1100709df78aaffb44` on `codex/step-33-project-keychain-security`. This checkpoint reviews the path toward running the unchanged SwiftChat file. No runtime code was changed merely to silence a check.

## Verified paths

- The file link is persisted by `ProjectSourceFileStore`; `reloadAndRunApp` reads that link again, extracts the app entry, resets the interpreter, and lowers a root-view snapshot. Actions and native input/presentation callbacks return to the same kernel and refresh from the stored source snapshot.
- `ProjectKeychainModule` is installed on Security import and after reset. The four generic-password calls use a service prefixed by the stable `ProjectID`; unsupported query attributes return `errSecParam`. The target-shaped credential test covers read/add/update/delete, reset, reopen, and isolation with an injected backend.
- CI run #76 on the base commit passed 122 core tests and built the iOS device-SDK host. Its Keychain tests use `MemoryKeychainBackend`; the system Keychain backend was compiled, not exercised on a physical device.

## Concrete blockers to the unchanged target app

1. `InterpreterKernel.reloadAndRunApp` resets the interpreter and calls `lowerViewBodyInCurrentScope`, which seeds supported view state and evaluates extracted view expressions. It does not execute the target's top-level models, services, or view object initializers. `ChatStore` and `CodexSessionManager` therefore have no live instances in this path. The current view editor recognizes literal String/Bool `@State` cells but has no `@StateObject`/`@ObservedObject`/`@Published` lifecycle or change notification. This was already carried forward in `IMPLEMENTATION_TODO.md` and `TARGET_COMPATIBILITY.md`; the newer project checklist's claim that its observable-object step is done does not match this implementation.
2. The compatibility inventory identifies explicit `@ViewBuilder` helpers `conversationBody` and `authSummary`. `CustomViewSourceExpander.helperValues` deliberately skips computed properties marked `@ViewBuilder`; `SwiftUIViewExpressionLowerer.lower` requires a call or supported conditional and rejects a remaining bare helper reference. These helpers need actual builder expansion, including their target-used branches and local declarations.
3. The whole-source `reloadAndRun()` preflight still blocks the target's partial SwiftUI wrappers/builders. The app-preview `reloadAndRunApp()` bypass is intentional, but Step 35 must make its source evaluation and root lowering cooperate with model/service initialization instead of treating a green host build as proof of a working unchanged app.

These are functional gaps, not formatting issues. They require target-shaped implementation and tests before end-to-end acceptance. The original linked SwiftChat file is not in this repository; source-exact and physical-device acceptance must use that file in Step 35. Step 34 still supplies ordered GCD, URLSession, and streaming/cancellation behavior. Recheck the end-to-end gate only after the object lifecycle, builder expansion, model bootstrap, and networking paths are connected.
