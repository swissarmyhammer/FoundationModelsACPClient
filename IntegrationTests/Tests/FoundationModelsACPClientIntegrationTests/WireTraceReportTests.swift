import Foundation
import FoundationModelsACP
import Testing

// The fast tests of the wire trace text of a test issue. They use no agent
// process, so the suite has no build trait.

/// The ids of the small test trace.
private let root = SessionId(rawValue: "root")
private let child = SessionId(rawValue: "child-1")
private let resumeId = RequestId.number(1)

/// The name of the connection of the small test trace.
private let connection = "first"

/// An agent message chunk in a session stream.
private let messageChunk = SessionUpdate.agentMessageChunk(
    ContentChunk(content: .text(TextContent(text: "hello")), messageId: MessageId(rawValue: "message-1")))

/// The announcement of the child in the root stream.
private let announcement = WireTraceEvent.update(sessionId: root, update: .subagentUpdate(SubagentUpdate(sessionId: child)))

@Suite
struct WireTraceReportTests {
    /// Each event of a small trace gives one line with its position, the
    /// connection, the direction, the method, the session id and the kind.
    @Test
    func aSmallTraceGivesOneLineForEachEventWithItsPosition() {
        let events: [WireTraceEvent] = [
            .resumeRequest(id: resumeId, sessionId: root),
            announcement,
            .update(sessionId: child, update: messageChunk),
            .agentRequest(id: .number(2), method: "elicitation/create", sessionId: child),
            .resumeResponse(id: resumeId),
        ]
        #expect(
            WireTraceReport.traceLines(of: events, connection: connection) == [
                "0 first > session/resume root request",
                "1 first < session/update root subagent_update(child-1)",
                "2 first < session/update child-1 agent_message_chunk",
                "3 first < elicitation/create child-1 request",
                "4 first < session/resume - response",
            ])
    }

    /// A trace with an update of the child before its announcement records
    /// the ordered trace in the issue.
    @Test
    func aViolationRecordsTheOrderedTraceInTheIssue() {
        let events: [WireTraceEvent] = [
            .update(sessionId: root, update: messageChunk),
            .update(sessionId: child, update: messageChunk),
            announcement,
        ]
        withKnownIssue {
            WireTraceReport.expectNoViolations(in: events, connection: connection)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("1 first < session/update child-1 agent_message_chunk") }
        }
    }

    /// A trace that follows the rules records no issue.
    @Test
    func aValidTraceRecordsNoIssue() {
        WireTraceReport.expectNoViolations(
            in: [.update(sessionId: root, update: messageChunk), announcement, .update(sessionId: child, update: messageChunk)],
            connection: connection)
    }

    /// The frame text of a connection holds only the last frames, each with
    /// its number in the connection and its direction.
    @Test
    func theFrameTextHoldsOnlyTheLastFrames() {
        let frames = [
            WireFrame(isIncoming: false, text: "{\"a\":1}"),
            WireFrame(isIncoming: true, text: "{\"b\":2}"),
            WireFrame(isIncoming: true, text: "{\"c\":3}"),
        ]
        #expect(
            WireTraceReport.frameLines(of: frames, connection: connection, limit: 2) == [
                "The last 2 of the 3 frames of connection first:",
                "frame 1 first < {\"b\":2}",
                "frame 2 first < {\"c\":3}",
            ])
    }

    /// A trace transport that a test with the trait makes adds its frames to
    /// the log of the test.
    @Test(.wireFramesOnIssue)
    func aTraceTransportAddsItsFramesToTheLogOfTheTest() async throws {
        // The far end must live, because a write to a closed pair throws.
        let (near, far) = InMemoryTransport.pair()
        let trace = TraceTransport(wrapping: near, connection: connection)
        try await trace.write(Data("{\"jsonrpc\":\"2.0\",\"method\":\"probe\"}\n".utf8))
        withExtendedLifetime(far) {}
        let log = try #require(WireFrameLog.current)
        #expect(log.lastFramesText.contains("frame 0 first > {\"jsonrpc\":\"2.0\",\"method\":\"probe\"}"))
    }
}
