import Foundation
import FoundationModelsACP
import Testing

/// One frame that a ``TraceTransport`` recorded: one line of the wire.
struct WireFrame: Sendable {
    /// `true` for a frame from the agent to the client, `false` for a frame
    /// from the client to the agent.
    let isIncoming: Bool

    /// The text of the line, with no newline.
    let text: String
}

/// The text about the wire that a test issue holds: the ordered trace of a
/// connection, and the last frames of a connection.
///
/// Each line gives the direction as `>` (from the client to the agent) or
/// `<` (from the agent to the client).
enum WireTraceReport {
    /// The count of the last frames of each connection that an issue holds.
    static let lastFrameCount = 50

    /// The direction of a frame from the client to the agent.
    private static let toAgent = ">"

    /// The direction of a frame from the agent to the client.
    private static let toClient = "<"

    /// The text of a column that has no value.
    private static let noValue = "-"

    /// The wire method of a resume request and of its response.
    private static let resumeMethod = "session/resume"

    /// The wire method of a session update.
    private static let updateMethod = "session/update"

    /// The kind of a request in a trace line.
    private static let requestKind = "request"

    /// The key of the kind of a session update on the wire.
    private static let updateKindKey = "sessionUpdate"

    /// Checks a trace against the wire rules. When the trace breaks a rule,
    /// the issue holds the violations and the ordered trace, so that the
    /// position of each violation points to a line. A trace that follows the
    /// rules records nothing.
    ///
    /// - Parameters:
    ///   - events: The trace of one connection, in wire order.
    ///   - connection: The name of the connection.
    ///   - sourceLocation: The place that the issue names.
    static func expectNoViolations(
        in events: [WireTraceEvent],
        connection: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let violations = SubagentWireTraceValidator().validate(events)
        #expect(
            violations.isEmpty,
            Comment(rawValue: violationText(violations, events: events, connection: connection)),
            sourceLocation: sourceLocation)
    }

    /// The text of the violations of a trace, and then the ordered trace.
    ///
    /// - Parameters:
    ///   - violations: The violations of the trace.
    ///   - events: The trace, in wire order.
    ///   - connection: The name of the connection.
    /// - Returns: The text.
    private static func violationText(
        _ violations: [SubagentWireTraceValidator.Violation],
        events: [WireTraceEvent],
        connection: String
    ) -> String {
        let violationLines = violations.map { "position \($0.position), rule \($0.rule.rawValue): \($0.message)" }
        let header = "The ordered trace of connection \(connection) (position connection direction method session kind):"
        return (violationLines + [header] + traceLines(of: events, connection: connection)).joined(separator: "\n")
    }

    /// The lines of a trace, one for each event, in wire order.
    ///
    /// A line holds the position (the number that a violation names), the
    /// connection, the direction, the method, the session id and the kind.
    /// The kind of a session update is its `sessionUpdate` value, and a
    /// `subagent_update` also names the child. The kind of a request is
    /// `request`, and the kind of the resume response is `response`.
    ///
    /// - Parameters:
    ///   - events: The trace, in wire order.
    ///   - connection: The name of the connection.
    /// - Returns: The lines.
    static func traceLines(of events: [WireTraceEvent], connection: String) -> [String] {
        events.enumerated().map { position, event in
            let columns = columns(of: event)
            return [String(position), connection, columns.direction, columns.method, columns.session, columns.kind]
                .joined(separator: " ")
        }
    }

    /// The columns of one event of a trace, after its position and its
    /// connection.
    ///
    /// - Parameter event: The event.
    /// - Returns: The direction, the method, the session id and the kind.
    private static func columns(
        of event: WireTraceEvent
    ) -> (direction: String, method: String, session: String, kind: String) {
        switch event {
        case .resumeRequest(_, let sessionId):
            (toAgent, resumeMethod, sessionId.rawValue, requestKind)
        case .resumeResponse:
            (toClient, resumeMethod, noValue, "response")
        case .update(let sessionId, let update):
            (toClient, updateMethod, sessionId.rawValue, kind(of: update))
        case .agentRequest(_, let method, let sessionId):
            (toClient, method, sessionId.rawValue, requestKind)
        }
    }

    /// The kind of a session update: its `sessionUpdate` value on the wire.
    /// A `subagent_update` also names the child that it announces.
    ///
    /// - Parameter update: The session update.
    /// - Returns: The kind.
    private static func kind(of update: SessionUpdate) -> String {
        let encoded = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any]
        let name = encoded?[updateKindKey] as? String ?? noValue
        if case .subagentUpdate(let subagent) = update { return "\(name)(\(subagent.sessionId.rawValue))" }
        return name
    }

    /// The lines of the last frames of a connection: a header, and then one
    /// line for each frame with its number in the connection, the
    /// connection, the direction and the text.
    ///
    /// - Parameters:
    ///   - frames: All the frames of the connection, in wire order.
    ///   - connection: The name of the connection.
    ///   - limit: The largest count of frames to give.
    /// - Returns: The lines.
    static func frameLines(of frames: [WireFrame], connection: String, limit: Int = lastFrameCount) -> [String] {
        let first = max(frames.count - limit, 0)
        let header = "The last \(frames.count - first) of the \(frames.count) frames of connection \(connection):"
        let lines = frames[first...].enumerated().map { offset, frame in
            "frame \(first + offset) \(connection) \(frame.isIncoming ? toClient : toAgent) \(frame.text)"
        }
        return [header] + lines
    }
}
