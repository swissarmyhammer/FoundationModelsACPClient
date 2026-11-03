import Foundation
import FoundationModelsACP
import Synchronization

/// A pass-through transport that records the frames of one connection in wire
/// order, and turns them into a trace for `SubagentWireTraceValidator`.
///
/// The transport never decodes on the wire path and never reorders. The trace
/// holds the `session/update` notifications of the agent, the requests of the
/// agent that wait on the user, the `session/resume` requests of the client,
/// and the responses to them.
final class TraceTransport: ACPTransport, Sendable {
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The transport that this transport wraps.
    private let inner: any ACPTransport

    /// The forwarding task.
    private let forwarder: Task<Void, Never>

    /// Wraps a transport.
    ///
    /// - Parameter inner: The transport to wrap.
    init(wrapping inner: any ACPTransport) {
        self.inner = inner
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        bytes = stream
        let box = LineBox()
        self.box = box
        forwarder = Task {
            var framer = NDJSONFramer()
            do {
                for try await chunk in inner.bytes {
                    for line in framer.append(chunk) {
                        box.append(isIncoming: true, text: String(decoding: line, as: UTF8.self))
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// The shared store of the recorded lines.
    private let box: LineBox

    func write(_ data: Data) async throws {
        for part in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            box.append(isIncoming: false, text: String(part))
        }
        try await inner.write(data)
    }

    deinit {
        forwarder.cancel()
    }

    /// The frames that the trace could not read: a line that is not JSON, and
    /// a `session/update` whose params do not decode. A test must find none,
    /// because the validator never sees such a frame.
    var decodeFailures: [String] {
        read().failures
    }

    /// The trace of the recorded frames, in wire order.
    var events: [WireTraceEvent] {
        read().trace
    }

    /// Reads each recorded line.
    ///
    /// - Returns: The trace, and the lines that it could not read.
    private func read() -> (trace: [WireTraceEvent], failures: [String]) {
        var trace: [WireTraceEvent] = []
        var failures: [String] = []
        var resumeIds: Set<RequestId> = []
        for line in box.lines {
            guard let data = line.text.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                failures.append("not a JSON object: \(line.text)")
                continue
            }
            let id = object["id"].flatMap { Self.decodeJSON(RequestId.self, from: $0) }
            let method = object["method"] as? String
            let params = object["params"] as? [String: Any]
            if line.isIncoming, method == "session/update" {
                if let params, let notification = Self.decodeJSON(UpdateSessionNotification.self, from: params) {
                    trace.append(.update(sessionId: notification.sessionId, update: notification.update))
                } else {
                    failures.append("a session/update that does not decode: \(line.text)")
                }
            } else if line.isIncoming, let method, let id,
                ["session/request_permission", "elicitation/create"].contains(method)
            {
                if let sessionId = Self.sessionId(in: params) {
                    trace.append(.agentRequest(id: id, method: method, sessionId: sessionId))
                } else {
                    failures.append("a request without a session id: \(line.text)")
                }
            } else if !line.isIncoming, method == "session/resume", let id {
                resumeIds.insert(id)
                if let sessionId = Self.sessionId(in: params) {
                    trace.append(.resumeRequest(id: id, sessionId: sessionId))
                } else {
                    failures.append("a resume request without a session id: \(line.text)")
                }
            } else if line.isIncoming, method == nil, let id, resumeIds.contains(id) {
                trace.append(.resumeResponse(id: id))
            }
        }
        return (trace, failures)
    }

    /// Reads the session id of the params of a request: `sessionId`, or the
    /// session of the `scope` of an elicitation.
    private static func sessionId(in params: [String: Any]?) -> SessionId? {
        if let raw = params?["sessionId"] as? String { return SessionId(rawValue: raw) }
        if let scope = params?["scope"] as? [String: Any], let raw = scope["sessionId"] as? String {
            return SessionId(rawValue: raw)
        }
        return nil
    }

    /// Decodes a value from a JSON value that `JSONSerialization` read.
    private static func decodeJSON<Value: Decodable>(_ type: Value.Type, from value: Any) -> Value? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// The store of the recorded lines of a ``TraceTransport``, under one lock.
private final class LineBox: Sendable {
    /// One recorded line.
    struct Recorded {
        let isIncoming: Bool
        let text: String
    }

    private let store = Mutex<[Recorded]>([])

    func append(isIncoming: Bool, text: String) {
        store.withLock { $0.append(Recorded(isIncoming: isIncoming, text: text)) }
        // A debugging aid: the variable names a file that receives each frame.
        if let path = ProcessInfo.processInfo.environment["ACP_TRACE_FILE"],
            let data = ((isIncoming ? "< " : "> ") + text + "\n").data(using: .utf8)
        {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    var lines: [Recorded] {
        store.withLock { $0 }
    }
}
