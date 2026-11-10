import Foundation
import FoundationModelsACP
import Synchronization
import Testing

/// A pass-through transport that records the frames of one connection in wire
/// order, and turns them into a trace for `SubagentWireTraceValidator`.
///
/// The transport never decodes on the wire path and never reorders. The trace
/// holds the `session/update` notifications of the agent, the requests of the
/// agent that wait on the user, the `session/resume` requests of the client,
/// and the responses to them.
///
/// In a test with the ``WireFramesOnIssueTrait``, the transport adds its frames
/// to the ``WireFrameLog`` of the test, so that an issue of the test holds the
/// last frames.
final class TraceTransport: ACPTransport, Sendable {
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The transport that this transport wraps.
    private let inner: any ACPTransport

    /// The forwarding task.
    private let forwarder: Task<Void, Never>

    /// The name of the connection in the text of an issue.
    let connection: String

    /// Wraps a transport.
    ///
    /// - Parameters:
    ///   - inner: The transport to wrap.
    ///   - connection: The name of the connection in the text of an issue,
    ///     for example `first` or `second`.
    init(wrapping inner: any ACPTransport, connection: String) {
        self.inner = inner
        self.connection = connection
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        bytes = stream
        let box = LineBox()
        self.box = box
        WireFrameLog.current?.add(connection: connection) { box.lines }
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

    /// Waits until an incoming frame holds a text. The client model has no
    /// value for some fields of a frame, such as the background list of a
    /// state update, so a test waits on the raw frame. The wait polls, and a
    /// cancel of the task or the time limit of the test ends it.
    ///
    /// - Parameter text: The text that an incoming frame must hold.
    /// - Throws: `CancellationError` when the task is cancelled.
    func waitForIncomingFrame(containing text: String) async throws {
        while !box.lines.contains(where: { $0.isIncoming && $0.text.contains(text) }) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The trace of the recorded frames, in wire order.
    var events: [WireTraceEvent] {
        read().trace
    }

    /// Checks the recorded trace against the wire rules. Each frame must
    /// decode, and the trace must have no violation. The issue of a
    /// violation holds the ordered trace.
    ///
    /// - Parameter sourceLocation: The place that an issue names.
    func expectValidTrace(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(decodeFailures.isEmpty, "\(decodeFailures)", sourceLocation: sourceLocation)
        WireTraceReport.expectNoViolations(in: events, connection: connection, sourceLocation: sourceLocation)
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
    private let store = Mutex<[WireFrame]>([])

    func append(isIncoming: Bool, text: String) {
        store.withLock { $0.append(WireFrame(isIncoming: isIncoming, text: text)) }
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

    var lines: [WireFrame] {
        store.withLock { $0 }
    }
}
