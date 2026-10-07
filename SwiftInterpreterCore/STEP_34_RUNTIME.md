# Step 34: session concurrency, networking and SSE

Branch: `codex/step-34-concurrency-network-streaming`, forked from
`after_step_33_checkup_fix` at `9866c84033592316ee7f2fc6c04b5039717d6b6c`.
Earlier branches and `main` were not changed.

## Calls inventoried from `Clasp Version 5.0.swift`

- `DeviceCodeLoginOperation`: labeled serial queue; `async` start and
  cancellation; cancellable `DispatchWorkItem` sent with `asyncAfter`; private
  URLSession for user code, approval polling and authorization-code exchange;
  `URLSessionDataTask.resume/cancel` and session invalidation.
- `CodexSessionManager`: serial credential queue, Main-queue state updates,
  single-flight refresh via `URLSession.shared.dataTask(with:)` completion.
- `CodexChatProvider`: model request through the same completion form, and a
  request for streaming responses through a delegate-backed session.
- `DeferredStreamHandle` and `CodexSSEStreamOperation`: `NSLock`, task and
  session cancellation, delegate response/data/completion/invalid callbacks.
  The target's `Data` line buffer handles CRLF, partial lines, multiple lines
  per chunk, terminal events and error events. `GenerationCoordinator` sends
  deltas and completion back to the Main queue. The delegate's final callback
  calls `finishTasksAndInvalidate()`; its CRLF path calls `Data.removeLast()`.

The app calls `auth.openai.com` and `chatgpt.com`; these two hosts are the
kernel's explicit network allow-list. Requests are authorized before a native
task is created. Model/service callbacks and their native resources belong
to an interpreter generation. Queue callbacks return through the kernel's
evaluation slot. A successful reload or reset cancels pending work and tasks;
callbacks from the former generation cannot enter the new interpreter.

`NSLock` calls in interpreted code are serialized by that same slot, so they
do not block the actor. The script still sees the lock/unlock call sequence.
The native task and work-item cancellation gates suppress queued callbacks
after cancellation. SwiftScript now passes trailing closures to bridged
initializers, seeds optional class fields with `nil`, and accepts the
zero-start partial range used by the SSE `Data` buffer. Its method registry
holds one method per base name, so the source adapter gives the four
`urlSession` delegate callbacks distinct internal method names. Optional
class method dispatch covers the target's `[weak self] in self?.pollForApproval()`.

## Verification

Target-shaped tests cover queue order, Main-queue delivery, delayed work and
cancel, asynchronous `@Published` view refresh, reload isolation, request
completion and transport failure, fragmented/coalesced SSE lines, terminal
events, delegate failure and stream cancellation, and device-code polling through token and
model requests. Network tests use an injected URLProtocol and do not use
live credentials. A physical-device run of the evolving Clasp prototype
belongs to Step 35.
