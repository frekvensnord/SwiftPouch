# Step 35: original SwiftChat acceptance evidence

Branch: `codex/step-35-original-app-acceptance`, based on the completed Step 34
commit `b45bd7e3e003e875bf990f1ed99f82ebf258704a`. This document records
evidence, not an assertion that device acceptance has already passed.

## Exact source and saved link

- Original attachment: `Clasp Version 5.0.swift`, 2,111 lines, SHA-256
  `774870ae19e3825ab75e4fa8411d3e563b8ba631acab4cccde4d493caf134490`.
- Byte-identical test resource:
  `Tests/SwiftInterpreterCoreTests/Fixtures/SwiftChatApp_Step5(1).swift`.
  It is copied as a resource, not compiled as another `@main` app or edited.
- The host persists a project-specific bookmark in `ProjectSourceFileStore`.
  The exact-source Core test links the resource, invokes `reloadAndRunApp()`,
  reopens the same workspace in a new kernel, and reloads from the existing
  bookmark without calling `linkSourceFile` again. Passing this test will
  establish the Core link/reload path, not the iOS Files-provider behavior.
- The pre-existing saved bookmark **on an iPhone** is not available to this
  CI runner or Linux workspace. Its identity and continued access must be
  checked in the installed host on the device.

## Target and toolchain

| Item | Pinned value or target |
| --- | --- |
| Physical acceptance device | iPhone 13, iOS 27; not connected to this runner |
| CI compiler | Xcode 27.0 (27A266a), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), iOS SDK 27.0 |
| Package tools / deployment | Swift tools 6.3; iOS minimum 26 |
| Host language mode / deployment | Swift 6.0; iOS minimum 26 |
| Vendored SwiftScript base | `d298d01dc1aa34d68700f7d0e37ad26b52b36dfc`, plus tracked local changes |

Both `SwiftInterpreterCore/Package.resolved` and the host workspace's
`Package.resolved` pin these same remote dependencies:

| Package | Revision | Version |
| --- | --- | --- |
| ShellKit | `40c1b417e6c6318d2ca644d9a3062dc6befd0e31` | revision pin |
| swift-syntax | `79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1` | 603.0.2 |
| swift-argument-parser | `6a52f3251125d74daf04fcbd5e6f08a75d074382` | 1.8.2 |
| swift-subprocess | `11633673a41f509f8945f23c96c7acd4adafd679` | 0.5.0 |
| swift-system | `869129b7bf4ecc57b97d0193ad29690ca2134750` | 1.8.1 |

## Physical-device acceptance record

No item below has been verified on the target device. Install a signed host
from this branch on the iPhone 13 with iOS 27, place the byte-identical
original file in Files, select it once, and record the linked filename and
project identity. Then record an actual result for each path:

| Path | Device result |
| --- | --- |
| First start, original link, entire initial surface | Pending |
| Quit/reopen host and Reload & Run without file re-selection | Pending |
| Compose text, send, model and reasoning choice | Pending |
| History, settings, local conversation/settings persistence and restoration | Pending |
| Device-code login, project Keychain isolation, restored login | Pending |
| Incremental answer, terminal answer, transport/server errors, cancellation | Pending |
| Reload while actions or network callbacks are pending; old session isolated | Pending |

Record the device's exact iOS build, host commit and signing identity, the
observed UI state for each action, and sanitized diagnostics for any failure.
Do not store device codes, tokens, account identifiers or chat content in CI
logs or this document. An unsigned generic iOS SDK build and mocked network
tests cannot replace these device observations.
