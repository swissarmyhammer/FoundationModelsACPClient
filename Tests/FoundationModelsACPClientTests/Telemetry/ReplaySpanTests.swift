import FoundationModelsACP
import InMemoryTracing
import TelemetryTestSupport
import Testing
import Tracing

@testable import FoundationModelsACPClient

// These tests cover the replay span of `ConnectionModel.resumeSession(_:)`:
// one internal span for each resume, the `session/resume` request span as its
// child, the `replayFrom` cursor as a fixed value, and the number of updates
// that the agent replayed before its response.
//
// Each test runs in a `TelemetryCapture`, which binds its tracer as the
// task-local tracer. `ConnectedModel` gives the real ACP wire, with a
// `ScriptedStubAgent` on the agent end. The stub sends its
// `resumeSessionScript` before it answers `session/resume`, and its `script`
// during `session/prompt`.

/// The fixtures of the replay span tests.
private enum ReplaySpanFixtures {
    /// The working directory of each request.
    static let workingDirectory = AbsolutePath(rawValue: "/")

    /// A replay cursor of a type that this schema revision does not know.
    static let replayFromUnknownCursor: ReplayFrom = .unknown("cursor", .object([:]))

    /// The text of the replayed agent message. Rule 4: no span, log record
    /// or metric holds it.
    static let replayedText = "Replayed answer: the copper lantern hums."

    /// The text of the live agent message that the agent sends during a
    /// prompt. Rule 4: no span, log record or metric holds it.
    static let liveText = "Live answer: the violet ferry leaves at dawn."

    /// The content that the capture of each test forbids.
    static let forbiddenContent = [replayedText, liveText]

    /// The updates that the agent replays before its `session/resume`
    /// answer: one agent message in two chunks, and the turn end.
    static let replayedUpdates = [
        agentChunk(text: "Replayed answer: ", message: "agent-1"),
        agentChunk(text: "the copper lantern hums.", message: "agent-1"),
        idleState(stopReason: .endTurn),
    ]

    /// The updates that the agent sends during a prompt, after the replay
    /// ended.
    static let liveUpdates = [
        agentChunk(text: liveText, message: "agent-2"),
        idleState(stopReason: .endTurn),
    ]

    /// The content of the prompt that follows the replay.
    static let promptContent: [ContentBlock] = [textBlock("Continue the session.")]

    /// The error that the agent refuses a resume with.
    static let resumeRefusal = RequestError.invalidParams

    /// The number of resumes in the test of two resumes of one session.
    static let twoResumes = 2

    /// Gives a resume request of the test session.
    ///
    /// - Parameter replayFrom: The replay cursor, or `nil` for no replay.
    /// - Returns: The request.
    static func resumeRequest(replayFrom: ReplayFrom?) -> ResumeSessionRequest {
        ResumeSessionRequest(cwd: workingDirectory, sessionId: testSession, replayFrom: replayFrom)
    }

    /// Connects a model that applies each chunk at once to a stub agent that
    /// replays ``replayedUpdates`` before each `session/resume` answer, and
    /// sends ``liveUpdates`` during each prompt.
    ///
    /// - Parameters:
    ///   - resumeSessionError: The error the agent refuses each resume with,
    ///     or `nil` to accept each resume.
    ///   - resumeSessionGate: The gate that must open, after the replay,
    ///     before the agent answers `session/resume`, or `nil` to answer at
    ///     once.
    /// - Returns: The connected model, after `initialize`.
    /// - Throws: Whatever `initialize` threw.
    @MainActor
    static func connect(
        resumeSessionError: RequestError? = nil,
        resumeSessionGate: UpdateGate? = nil
    ) async throws -> ConnectedModel {
        let connected = await ConnectedModel(model: ConnectionModel(coalescingCadence: .zero)) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: liveUpdates,
                resumeSessionScript: replayedUpdates,
                resumeSessionError: resumeSessionError,
                resumeSessionGate: resumeSessionGate,
                capabilities: InitializeFixtures.baselineCapabilities
            )
        }
        try await connected.initialize()
        return connected
    }

    /// Gives the replayed update count of a replay span.
    ///
    /// - Parameter count: The number of replayed updates.
    /// - Returns: The attribute value that the span holds for `count`.
    static func updateCountAttribute(_ count: Int) -> SpanAttribute {
        .int64(Int64(count))
    }
}

/// The replay span tests, in one suite so that
/// `swift test --filter ReplaySpanTests` selects them. A wait for an update
/// that never comes would suspend for ever, so the suite has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReplaySpanTests {
    /// A resume from the start gives one internal replay span with the
    /// session id, the cursor, and the number of replayed updates.
    @Test func aResumeFromTheStartGivesOneInternalReplaySpanWithTheUpdateCount() async throws {
        try await TelemetryCapture.run(forbidding: ReplaySpanFixtures.forbiddenContent) { context in
            let connected = try await ReplaySpanFixtures.connect()

            _ = try await connected.model.resumeSession(
                ReplaySpanFixtures.resumeRequest(replayFrom: SessionModelFixtures.replayFromStart)
            )

            #expect(context.replaySpans.count == 1)
            let span = try #require(context.replaySpans.first)
            #expect(span.kind == .internal)
            #expect(span.attributes.get(ACPClientTelemetry.AttributeKey.sessionID) == .string(testSession.rawValue))
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.replayFrom)
                    == .string(ACPClientTelemetry.ReplayFromValue.start)
            )
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.replayUpdateCount)
                    == ReplaySpanFixtures.updateCountAttribute(ReplaySpanFixtures.replayedUpdates.count)
            )
            #expect(span.status?.code != .error)
        }
    }

    /// The `session/resume` request span is a child of the replay span, in
    /// the trace of the replay.
    @Test func theResumeRequestSpanIsAChildOfTheReplaySpan() async throws {
        try await TelemetryCapture.run(forbidding: ReplaySpanFixtures.forbiddenContent) { context in
            let connected = try await ReplaySpanFixtures.connect()

            _ = try await connected.model.resumeSession(
                ReplaySpanFixtures.resumeRequest(replayFrom: SessionModelFixtures.replayFromStart)
            )

            let replaySpan = try #require(context.replaySpans.first)
            let requestSpan = try #require(context.requestSpans(of: ClientRequestSpan.Method.resumeSession).first)
            #expect(requestSpan.traceID == replaySpan.traceID)
            #expect(requestSpan.parentSpanID == replaySpan.spanID)
        }
    }

    /// A resume with no cursor asks for no replay, so the span has the
    /// `none` cursor and a count of 0, also when the agent sends updates
    /// before its response.
    @Test func aResumeWithNoCursorGivesTheNoneValueAndACountOfZero() async throws {
        try await TelemetryCapture.run(forbidding: ReplaySpanFixtures.forbiddenContent) { context in
            let connected = try await ReplaySpanFixtures.connect()

            _ = try await connected.model.resumeSession(ReplaySpanFixtures.resumeRequest(replayFrom: nil))

            let span = try #require(context.replaySpans.first)
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.replayFrom)
                    == .string(ACPClientTelemetry.ReplayFromValue.none)
            )
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.replayUpdateCount)
                    == ReplaySpanFixtures.updateCountAttribute(0)
            )
        }
    }

    /// A cursor of a type that this schema revision does not know gives the
    /// `other` value, and never the type that the caller sent.
    @Test func aCursorOfAnUnknownTypeGivesTheOtherValue() async throws {
        try await TelemetryCapture.run(forbidding: ReplaySpanFixtures.forbiddenContent) { context in
            let connected = try await ReplaySpanFixtures.connect()

            _ = try await connected.model.resumeSession(
                ReplaySpanFixtures.resumeRequest(replayFrom: ReplaySpanFixtures.replayFromUnknownCursor)
            )

            let span = try #require(context.replaySpans.first)
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.replayFrom)
                    == .string(ACPClientTelemetry.ReplayFromValue.other)
            )
        }
    }

    /// A resume that the agent refuses gives a replay span with the error
    /// status and the count of the updates that came before the refusal. The
    /// span records no error object, and no record holds the error message.
    @Test func aRefusedResumeGivesAnErrorReplaySpanWithACount() async throws {
        let refusal = ReplaySpanFixtures.resumeRefusal
        try await TelemetryCapture.run(forbidding: ReplaySpanFixtures.forbiddenContent + [refusal.message]) { context in
            let connected = try await ReplaySpanFixtures.connect(resumeSessionError: refusal)

            await #expect(throws: refusal) {
                try await connected.model.resumeSession(
                    ReplaySpanFixtures.resumeRequest(replayFrom: SessionModelFixtures.replayFromStart)
                )
            }

            let span = try #require(context.replaySpans.first)
            #expect(span.status?.code == .error)
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.replayUpdateCount)
                    == ReplaySpanFixtures.updateCountAttribute(ReplaySpanFixtures.replayedUpdates.count)
            )
            #expect(span.errors.isEmpty, "The span recorded the error object: \(span.errors.map(\.error)).")
        }
    }

    /// A replay whose subscription ends before the marker of the response
    /// ends as a failure, so its span gets the error status, although the
    /// agent answered the request.
    @Test func aReplayWhoseSubscriptionEndsBeforeTheMarkerGivesTheErrorStatus() async throws {
        try await TelemetryCapture.run(forbidding: ReplaySpanFixtures.forbiddenContent) { context in
            let answerGate = UpdateGate()
            let connected = try await ReplaySpanFixtures.connect(resumeSessionGate: answerGate)
            let session = try await connected.model.newSession(NewSessionRequest(cwd: ReplaySpanFixtures.workingDirectory))
            let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
            session.attach(subscription)
            let resuming = Task { [model = connected.model] in
                try await model.resumeSession(
                    ReplaySpanFixtures.resumeRequest(replayFrom: SessionModelFixtures.replayFromStart)
                )
            }
            try await waitUntil { connected.receivedMethods.contains(ClientRequestSpan.Method.resumeSession) }

            // The gate holds the answer of the agent, so the subscription
            // ends before the marker of the response can arrive.
            continuation.finish()
            try await waitUntil { !session.isReplaying }
            answerGate.open()
            _ = try await resuming.value

            let span = try #require(context.replaySpans.first)
            #expect(span.status?.code == .error)
        }
    }

    /// Two resumes of one session, one after the other, give two replay
    /// spans, and each span counts only the updates of its own replay.
    @Test func twoResumesOfOneSessionGiveTwoReplaySpansWithTheirOwnCounts() async throws {
        try await TelemetryCapture.run(forbidding: ReplaySpanFixtures.forbiddenContent) { context in
            let connected = try await ReplaySpanFixtures.connect()
            let request = ReplaySpanFixtures.resumeRequest(replayFrom: SessionModelFixtures.replayFromStart)

            for _ in 0..<ReplaySpanFixtures.twoResumes {
                _ = try await connected.model.resumeSession(request)
            }

            let counts = context.replaySpans.map {
                $0.attributes.get(ACPClientTelemetry.AttributeKey.replayUpdateCount)
            }
            let expected = ReplaySpanFixtures.updateCountAttribute(ReplaySpanFixtures.replayedUpdates.count)
            #expect(counts == Array(repeating: expected, count: ReplaySpanFixtures.twoResumes))
        }
    }

    /// The live updates that come after the replay ended do not change the
    /// replayed update count of the session.
    @Test func liveUpdatesAfterTheReplayDoNotChangeTheCount() async throws {
        try await TelemetryCapture.run(forbidding: ReplaySpanFixtures.forbiddenContent) { context in
            let connected = try await ReplaySpanFixtures.connect()
            let session = try await connected.model.resumeSession(
                ReplaySpanFixtures.resumeRequest(replayFrom: SessionModelFixtures.replayFromStart)
            )

            _ = try await session.prompt(ReplaySpanFixtures.promptContent)
            try await waitUntil { session.transcript.contains { $0.agentMessage?.content.joinedText == ReplaySpanFixtures.liveText } }

            #expect(session.replayedUpdateCount == ReplaySpanFixtures.replayedUpdates.count)
            let span = try #require(context.replaySpans.first)
            #expect(
                span.attributes.get(ACPClientTelemetry.AttributeKey.replayUpdateCount)
                    == ReplaySpanFixtures.updateCountAttribute(ReplaySpanFixtures.replayedUpdates.count)
            )
        }
    }
}
