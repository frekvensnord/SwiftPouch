import Foundation
import ShellKit
import SwiftScriptInterpreter
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Calls into a script are owned by one interpreter generation. Foundation's
/// callbacks never touch the interpreter on their URLSession/Dispatch threads.
enum SessionCallback: Sendable {
    case function(Value, [Value], SessionWorkItem?)
    case delegate(Value, String, [Value], SessionWorkItem?)
}

private actor SessionCallbackQueues {
    private var pending: [String: [SessionCallback]] = [:]
    private var running: Set<String> = []

    func append(_ callback: SessionCallback, to name: String, runtime: SessionAsyncBridge) {
        pending[name, default: []].append(callback)
        guard running.insert(name).inserted else { return }
        Task { await drain(name, runtime: runtime) }
    }

    private func drain(_ name: String, runtime: SessionAsyncBridge) async {
        while var items = pending[name], !items.isEmpty {
            let first = items.removeFirst()
            pending[name] = items
            await runtime.deliver(first)
        }
        pending.removeValue(forKey: name)
        running.remove(name)
    }
}

final class SessionWorkItem: @unchecked Sendable {
    let body: Value
    private let lock = NSLock()
    private var cancelled = false
    private var timer: Task<Void, Never>?

    init(_ body: Value) { self.body = body }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func attach(_ timer: Task<Void, Never>) {
        lock.withLock {
            if cancelled { timer.cancel() } else { self.timer = timer }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            timer?.cancel()
            timer = nil
        }
    }
}

private final class SessionQueue: @unchecked Sendable {
    let name: String
    init(_ name: String) { self.name = name }
}

private final class SessionTaskRecord: @unchecked Sendable {
    let task: URLSessionTask
    let session: URLSession
    let callbackGate: SessionWorkItem
    private let lock = NSLock()
    private var cancelled = false
    init(_ task: URLSessionTask, session: URLSession, callbackGate: SessionWorkItem) {
        self.task = task
        self.session = session
        self.callbackGate = callbackGate
    }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() {
        lock.withLock { cancelled = true }
        callbackGate.cancel()
        task.cancel()
    }
}

/// The only owner of outstanding native work. Invalidating it cancels delayed
/// closures, requests and streams; the kernel also checks its generation at
/// delivery time so a callback already in flight cannot mutate a new scope.
final class SessionAsyncBridge: @unchecked Sendable {
    let generation: UUID
    private let queues = SessionCallbackQueues()
    private let receiver: @Sendable (UUID, SessionCallback) async -> Void
    private let lock = NSLock()
    private var active = true
    private var workItems: [SessionWorkItem] = []
    private var immediateTails: [String: Task<Void, Never>] = [:]
    private var tasks: [ObjectIdentifier: SessionTaskRecord] = [:]
    private var sessions: [URLSession] = []
    private let configuration: URLSessionConfiguration?

    init(generation: UUID, configuration: URLSessionConfiguration? = nil,
         receiver: @escaping @Sendable (UUID, SessionCallback) async -> Void) {
        self.generation = generation
        self.configuration = configuration
        self.receiver = receiver
    }

    var isActive: Bool { lock.withLock { active } }

    func invalidate() {
        let resources = lock.withLock { () -> ([SessionWorkItem], [SessionTaskRecord], [URLSession]) in
            active = false
            let result = (workItems, Array(tasks.values), sessions)
            workItems.removeAll()
            immediateTails.removeAll()
            tasks.removeAll()
            sessions.removeAll()
            return result
        }
        resources.0.forEach { $0.cancel() }
        resources.1.forEach { $0.cancel() }
        resources.2.forEach { $0.invalidateAndCancel() }
    }

    func deliver(_ event: SessionCallback) async {
        guard isActive else { return }
        await receiver(generation, event)
    }

    func enqueue(_ event: SessionCallback, queue: String) async {
        guard isActive else { return }
        await queues.append(event, to: queue, runtime: self)
    }

    func dispatch(_ body: Value, queue: String, delay: TimeInterval = 0,
                  item: SessionWorkItem? = nil) {
        let work = item ?? SessionWorkItem(body)
        let timer = lock.withLock { () -> Task<Void, Never>? in
            guard active else { return nil }
            workItems.append(work)
            // Register immediate work synchronously in source order. Task
            // scheduling alone does not guarantee two consecutive async
            // calls reach the queue actor in their original order.
            let predecessor = delay <= 0 ? immediateTails[queue] : nil
            let timer = Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                await predecessor?.value
                guard !Task.isCancelled, !work.isCancelled, let self else { return }
                await self.enqueue(.function(work.body, [], work), queue: queue)
            }
            if delay <= 0 { immediateTails[queue] = timer }
            return timer
        }
        guard let timer else { work.cancel(); return }
        work.attach(timer)
    }

    private func track(_ task: URLSessionTask, session: URLSession,
                       gate: SessionWorkItem = SessionWorkItem(.void)) -> SessionTaskRecord {
        let record = SessionTaskRecord(task, session: session, callbackGate: gate)
        let accepted = lock.withLock { () -> Bool in
            guard active else { return false }
            tasks[ObjectIdentifier(task)] = record
            return true
        }
        if !accepted { record.cancel() }
        return record
    }

    private func record(for task: URLSessionTask) -> SessionTaskRecord? {
        lock.withLock { tasks[ObjectIdentifier(task)] }
    }

    private func invalidate(_ session: URLSession) {
        let related = lock.withLock { tasks.values.filter { $0.session === session } }
        related.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }

    private func makeSession(_ configuration: URLSessionConfiguration,
                             delegate: URLSessionDataDelegate? = nil) -> URLSession {
        let config = self.configuration ?? configuration
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        let accepted = lock.withLock { () -> Bool in
            guard active else { return false }
            sessions.append(session)
            return true
        }
        if !accepted { session.invalidateAndCancel() }
        return session
    }

    /// Allows a scripted URLSession delegate to receive native events through
    /// the kernel's evaluation slot, preserving the per-session delegate order.
    private final class DelegateProxy: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        let value: Value
        let runtime: SessionAsyncBridge
        private let lock = NSLock()
        private var tail: Task<Void, Never>?

        init(value: Value, runtime: SessionAsyncBridge) {
            self.value = value
            self.runtime = runtime
        }

        private func send(_ method: String, _ arguments: [Value], task: URLSessionTask? = nil) {
            lock.withLock {
                let previous = tail
                let gate = task.flatMap { runtime.record(for: $0)?.callbackGate }
                tail = Task {
                    await previous?.value
                    await runtime.deliver(.delegate(value, method, arguments, gate))
                }
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let handler = Value.function(Function(name: "__swiftpouch_response_disposition", parameters: [],
                kind: .builtin { values in
                    let allow = values.first.map { value -> Bool in
                        if case .enumValue(_, let name, _) = value { return name == "allow" }
                        return false
                    } ?? false
                    completionHandler(allow ? .allow : .cancel)
                    return .void
                }))
            send("response", [.opaque(typeName: "URLSession", value: session),
                              .opaque(typeName: "URLSessionDataTask", value: dataTask),
                              .opaque(typeName: "URLResponse", value: response), handler], task: dataTask)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            send("data", [.opaque(typeName: "URLSession", value: session),
                          .opaque(typeName: "URLSessionDataTask", value: dataTask),
                          .opaque(typeName: "Data", value: data)], task: dataTask)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            send("complete", [.opaque(typeName: "URLSession", value: session),
                              .opaque(typeName: "URLSessionTask", value: task),
                              .optional(error.map { .opaque(typeName: "Error", value: $0) })], task: task)
        }

        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
            send("invalid", [.opaque(typeName: "URLSession", value: session),
                             .optional(error.map { .opaque(typeName: "Error", value: $0) })])
        }
    }

    func register(into interpreter: Interpreter) {
        let main = Value.opaque(typeName: "DispatchQueue", value: SessionQueue("main"))
        interpreter.bridges["static let DispatchQueue.main"] = .staticValue(main)
        interpreter.bridges["init DispatchQueue(label:)"] = .`init` { args in
            guard args.count == 1, case .string(let label) = args[0] else {
                throw RuntimeError.invalid("DispatchQueue(label:) expects a label")
            }
            return .opaque(typeName: "DispatchQueue", value: SessionQueue(label))
        }
        let asyncQueueBridge = Bridge.method { receiver, args in
            guard case .opaque(_, let queue as SessionQueue) = receiver,
                  args.count == 1, case .function = args[0] else {
                throw RuntimeError.invalid("DispatchQueue.async expects a closure")
            }
            self.dispatch(args[0], queue: queue.name)
            return .void
        }
        interpreter.bridges["func DispatchQueue.async(_:)" ] = asyncQueueBridge
        interpreter.bridges["func DispatchQueue.async()"] = asyncQueueBridge
        interpreter.bridges["func DispatchQueue.asyncAfter(deadline:execute:)"] = .method { receiver, args in
            guard case .opaque(_, let queue as SessionQueue) = receiver,
                  args.count == 2, case .opaque(_, let work as SessionWorkItem) = args[1] else {
                throw RuntimeError.invalid("DispatchQueue.asyncAfter expects a deadline and work item")
            }
            let deadline: Double
            switch args[0] {
            case .double(let value): deadline = value
            case .int(let value): deadline = Double(value)
            default: throw RuntimeError.invalid("DispatchQueue.asyncAfter expects a numeric deadline")
            }
            self.dispatch(work.body, queue: queue.name,
                          delay: max(0, deadline - Date().timeIntervalSince1970), item: work)
            return .void
        }
        interpreter.bridges["static func DispatchTime.now()"] = .staticMethod { _ in
            .double(Date().timeIntervalSince1970)
        }
        interpreter.bridges["init DispatchWorkItem(_:)"] = .`init` { args in
            guard args.count == 1, case .function = args[0] else {
                throw RuntimeError.invalid("DispatchWorkItem expects a closure")
            }
            return .opaque(typeName: "DispatchWorkItem", value: SessionWorkItem(args[0]))
        }
        interpreter.bridges["func DispatchWorkItem.cancel()"] = .method { receiver, _ in
            guard case .opaque(_, let item as SessionWorkItem) = receiver else {
                throw RuntimeError.invalid("DispatchWorkItem.cancel receiver")
            }
            item.cancel()
            return .void
        }
        // All script execution is serialized by the kernel evaluation slot.
        // A script lock therefore guards the same critical section without
        // blocking the actor (which would deadlock a resumed callback).
        interpreter.bridges["init NSLock()"] = .`init` { _ in
            .opaque(typeName: "NSLock", value: NSLock())
        }
        interpreter.bridges["func NSLock.lock()"] = .method { _, _ in .void }
        interpreter.bridges["func NSLock.unlock()"] = .method { _, _ in .void }

        interpreter.bridges["static let URLSessionConfiguration.ephemeral"] = .staticComputed {
            .opaque(typeName: "URLSessionConfiguration", value: URLSessionConfiguration.ephemeral)
        }
        interpreter.bridges["static let URLSessionConfiguration.default"] = .staticComputed {
            .opaque(typeName: "URLSessionConfiguration", value: URLSessionConfiguration.default)
        }
        interpreter.bridges["set var URLSessionConfiguration.timeoutIntervalForRequest: Double"] = .setter { receiver, value in
            guard case .opaque(_, let config as URLSessionConfiguration) = receiver else { return }
            config.timeoutIntervalForRequest = try Self.number(value)
        }
        interpreter.bridges["set var URLSessionConfiguration.timeoutIntervalForResource: Double"] = .setter { receiver, value in
            guard case .opaque(_, let config as URLSessionConfiguration) = receiver else { return }
            config.timeoutIntervalForResource = try Self.number(value)
        }
        interpreter.bridges["var URLSessionConfiguration.timeoutIntervalForRequest: Double"] = .computed { receiver in
            guard case .opaque(_, let config as URLSessionConfiguration) = receiver else { return .void }
            return .double(config.timeoutIntervalForRequest)
        }
        interpreter.bridges["var URLSessionConfiguration.timeoutIntervalForResource: Double"] = .computed { receiver in
            guard case .opaque(_, let config as URLSessionConfiguration) = receiver else { return .void }
            return .double(config.timeoutIntervalForResource)
        }
        interpreter.bridges["init URLSession(configuration:)"] = .`init` { args in
            guard args.count == 1, case .opaque(_, let config as URLSessionConfiguration) = args[0] else {
                throw RuntimeError.invalid("URLSession(configuration:) expects a configuration")
            }
            return .opaque(typeName: "URLSession", value: self.makeSession(config))
        }
        interpreter.bridges["init URLSession(configuration:delegate:delegateQueue:)"] = .`init` { args in
            guard args.count == 3, case .opaque(_, let config as URLSessionConfiguration) = args[0],
                  case .classInstance = args[1] else {
                throw RuntimeError.invalid("URLSession delegate must be an interpreted object")
            }
            let proxy = DelegateProxy(value: args[1], runtime: self)
            return .opaque(typeName: "URLSession", value: self.makeSession(config, delegate: proxy))
        }
        interpreter.bridges["static let URLSession.shared"] = .staticComputed {
            .opaque(typeName: "URLSession", value: self.makeSession(.default))
        }
        interpreter.bridges["func URLSession.invalidateAndCancel()"] = .method { receiver, _ in
            guard case .opaque(_, let session as URLSession) = receiver else {
                throw RuntimeError.invalid("URLSession.invalidateAndCancel receiver")
            }
            self.invalidate(session)
            return .void
        }
        interpreter.bridges["func URLSession.finishTasksAndInvalidate()"] = .method { receiver, _ in
            guard case .opaque(_, let session as URLSession) = receiver else {
                throw RuntimeError.invalid("URLSession.finishTasksAndInvalidate receiver")
            }
            session.finishTasksAndInvalidate()
            return .void
        }
        interpreter.bridges["func URLSession.dataTask(with:)"] = .method { receiver, args in
            guard case .opaque(_, let session as URLSession) = receiver,
                  args.count == 1, case .opaque(_, let request as URLRequest) = args[0],
                  let url = request.url else { throw RuntimeError.invalid("URLSession.dataTask expects a request") }
            try await authorizeURL(url, method: request.httpMethod ?? "GET")
            let task = session.dataTask(with: request)
            _ = self.track(task, session: session)
            return .opaque(typeName: "URLSessionDataTask", value: task)
        }
        let completionTaskBridge = Bridge.method { receiver, args in
            guard case .opaque(_, let session as URLSession) = receiver,
                  args.count == 2, case .opaque(_, let request as URLRequest) = args[0],
                  case .function = args[1], let url = request.url else {
                throw RuntimeError.invalid("URLSession.dataTask expects a request and completion")
            }
            try await authorizeURL(url, method: request.httpMethod ?? "GET")
            let completion = args[1]
            let gate = SessionWorkItem(.void)
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self, !gate.isCancelled else { return }
                Task { await self.enqueue(.function(completion, [
                    .optional(data.map { .opaque(typeName: "Data", value: $0) }),
                    .optional(response.map { .opaque(typeName: "URLResponse", value: $0) }),
                    .optional(error.map { .opaque(typeName: "Error", value: $0) })
                ], gate), queue: "network-completion") }
            }
            _ = self.track(task, session: session, gate: gate)
            return .opaque(typeName: "URLSessionDataTask", value: task)
        }
        interpreter.bridges["func URLSession.dataTask(with:_:)"] = completionTaskBridge
        interpreter.bridges["func URLSession.dataTask(with:completionHandler:)"] = completionTaskBridge
        interpreter.bridges["func URLSessionDataTask.resume()"] = .method { receiver, _ in
            guard case .opaque(_, let task as URLSessionDataTask) = receiver else { return .void }
            if self.isActive, self.record(for: task)?.isCancelled == false { task.resume() }
            return .void
        }
        for name in ["URLSessionDataTask", "URLSessionTask"] {
            interpreter.bridges["func \(name).cancel()"] = .method { receiver, _ in
                guard case .opaque(_, let task as URLSessionTask) = receiver else { return .void }
                self.record(for: task)?.cancel()
                return .void
            }
        }
        interpreter.bridges["static let URLSession.ResponseDisposition.allow"] = .staticValue(
            .enumValue(typeName: "URLSession.ResponseDisposition", caseName: "allow", associatedValues: []))
        interpreter.bridges["var Error.localizedDescription: String"] = .computed { receiver in
            guard case .opaque(_, let error as any Error) = receiver else {
                throw RuntimeError.invalid("Error.localizedDescription receiver")
            }
            return .string(error.localizedDescription)
        }

        // The target's SSE line buffer uses Data's Collection operations.
        // The generated Foundation table covers append/removeFirst but omits
        // the index/range surface used when CRLF and frame boundaries split.
        interpreter.bridges["var Data.startIndex: Int"] = .computed { _ in .int(0) }
        interpreter.bridges["var Data.last: UInt8?"] = .computed { receiver in
            guard case .opaque(_, let bytes as Data) = receiver else { return .optional(nil) }
            return .optional(bytes.last.map { .int(Int($0)) })
        }
        interpreter.bridges["func Data.firstIndex(of:)"] = .method { receiver, args in
            guard case .opaque(_, let bytes as Data) = receiver,
                  args.count == 1, case .int(let byte) = args[0], (0...255).contains(byte) else {
                throw RuntimeError.invalid("Data.firstIndex(of:) expects a byte")
            }
            return .optional(bytes.firstIndex(of: UInt8(byte)).map { .int($0) })
        }
        interpreter.bridges["func Data.index(after:)"] = .method { _, args in
            guard args.count == 1, case .int(let index) = args[0] else {
                throw RuntimeError.invalid("Data.index(after:) expects an index")
            }
            return .int(index + 1)
        }
        interpreter.bridges["subscript Data.get"] = .subscriptGet { receiver, args in
            guard case .opaque(_, let bytes as Data) = receiver, args.count == 1 else {
                throw RuntimeError.invalid("Data subscript expects one index or range")
            }
            switch args[0] {
            case .int(let index) where bytes.indices.contains(index):
                return .int(Int(bytes[index]))
            case .range(let lower, let upper, let closed):
                let end = closed ? upper + 1 : upper
                guard lower >= 0, lower <= end, end <= bytes.count else {
                    throw RuntimeError.invalid("Data range out of bounds")
                }
                return .opaque(typeName: "Data", value: Data(bytes[lower..<end]))
            default:
                throw RuntimeError.invalid("Data range out of bounds")
            }
        }
        interpreter.bridges["init Data(_:)"] = .`init` { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Data initializer expects one value")
            }
            switch args[0] {
            case .opaque(_, let bytes as Data):
                return .opaque(typeName: "Data", value: bytes)
            case .string(let text):
                return .opaque(typeName: "Data", value: Data(text.utf8))
            case .array(let values):
                let bytes = try values.map { value -> UInt8 in
                    guard case .int(let byte) = value, (0...255).contains(byte) else {
                        throw RuntimeError.invalid("Data initializer expects bytes")
                    }
                    return UInt8(byte)
                }
                return .opaque(typeName: "Data", value: Data(bytes))
            default:
                throw RuntimeError.invalid("Data initializer expects bytes")
            }
        }
        interpreter.bridges["mutating func Data.removeSubrange(_:)"] = .mutatingMethod { receiver, args in
            guard case .opaque(_, let raw as Data) = receiver, args.count == 1,
                  case .range(let lower, let upper, let closed) = args[0] else {
                throw RuntimeError.invalid("Data.removeSubrange expects a range")
            }
            var bytes = raw
            let end = closed ? upper + 1 : upper
            guard lower >= 0, lower <= end, end <= bytes.count else {
                throw RuntimeError.invalid("Data range out of bounds")
            }
            bytes.removeSubrange(lower..<end)
            return (.void, .opaque(typeName: "Data", value: bytes))
        }
        // The generated Foundation no-argument overload mistakenly expects
        // an integer. SSE's CRLF handling calls this exact method.
        interpreter.bridges["mutating func Data.removeLast()"] = .mutatingMethod { receiver, args in
            guard case .opaque(_, let raw as Data) = receiver, args.isEmpty, !raw.isEmpty else {
                throw RuntimeError.invalid("Data.removeLast expects nonempty data" )
            }
            var bytes = raw
            let removed = bytes.removeLast()
            return (.int(Int(removed)), .opaque(typeName: "Data", value: bytes))
        }
    }

    private static func number(_ value: Value) throws -> Double {
        switch value {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: throw RuntimeError.invalid("expected a numeric interval")
        }
    }
}

private struct SessionAsyncModule: BuiltinModule {
    let name = "SwiftPouchSessionAsync"
    let runtime: SessionAsyncBridge
    func register(into interpreter: Interpreter) { runtime.register(into: interpreter) }
}

extension Interpreter {
    func registerSessionAsyncBridge(_ runtime: SessionAsyncBridge) {
        registerOnImport("Foundation", module: SessionAsyncModule(runtime: runtime))
    }
}
