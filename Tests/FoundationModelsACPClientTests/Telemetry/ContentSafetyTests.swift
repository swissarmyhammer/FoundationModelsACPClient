import Foundation
import FoundationModelsACP
import TelemetryTestSupport
import Testing

@testable import AcpClientCore
@testable import FoundationModelsACPClient

// The content-safety test of this package (rule 5 of the OpenTelemetry design
// of 2026-09-28). Rule 4: no span attribute, log message, log metadata value
// or metric dimension holds a prompt, a response, tool arguments, tool output
// or file content.
//
// Each test drives a whole turn of the real `AgentSession` and `TurnRunner`
// in a `TelemetryCapture`, through a `TracedSessionHarness`, with a
// `ScriptedStubAgent` on the far end. `TurnRunner.run()` calls
// `AgentSession.openSession()`, so the turn sends `initialize`,
// `session/new`, `session/prompt` and `session/close`.
//
// The code under test gets the telemetry of the capture globally: the capture
// binds its tracer and its metrics factory as the task-local values, and its
// log handler receives each record of a `Logger` that the code makes in the
// capture. The tests do not bootstrap the logging system: the capture does
// that one time for the process.
//
// The capture records one issue for each place that holds a forbidden string.
// Each test also makes sure that the capture saw at least one span, one log
// record and one metric. Without that check, a turn that wrote no telemetry
// would pass.

@Suite("content safety")
struct ContentSafetyTests {
    /// The fixture strings of the tests. Each string is distinct, so that a
    /// leak names the content that it came from.
    private enum Fixture {
        /// The text of the prompt.
        static let prompt = "Content-safety prompt: describe the violet heron."

        /// The text of the agent message chunk of the answer.
        static let answer = "Content-safety answer: the amber lantern is lit."

        /// The title of the tool call of the turn.
        static let toolTitle = "Content-safety tool title: read the cobalt ledger"

        /// The raw input of the tool call of the turn.
        static let toolInput = "Content-safety tool input: the cobalt ledger path"

        /// The raw output of the tool call of the turn.
        static let toolOutput = "Content-safety tool output: nine silver keys"

        /// The title of the permission request of the turn.
        static let permissionTitle = "Content-safety permission title: open the ledger?"

        /// The title of the tool call that the permission request is about.
        static let permissionToolTitle = "Content-safety permission tool title: write the ledger"

        /// A marker in the `cwd` of the session.
        static let workingDirectoryMarker = "content-safety-cwd-marker"

        /// The `cwd` of the session, which holds the marker.
        static let workingDirectory = "/private/tmp/\(workingDirectoryMarker)/workspace"

        /// The message text of the error that refuses a turn.
        static let refusalMessage = "Content-safety refusal: the crimson oath is secret."

        /// The data detail of the error that refuses a turn.
        static let refusalDetail = "Content-safety refusal detail: the crimson oath text"

        /// Each fixture string of the turn that the agent answers.
        static let answeredTurnContent = [
            prompt,
            answer,
            toolTitle,
            toolInput,
            toolOutput,
            permissionTitle,
            permissionToolTitle,
            workingDirectoryMarker,
        ]

        /// Each fixture string of the turn that the agent refuses.
        static let refusedTurnContent = [prompt, workingDirectoryMarker, refusalMessage, refusalDetail]
    }

    /// The raw id of the tool call of the turn.
    private static let toolCallID = ToolCallId(rawValue: "content-safety-call")

    /// The update that reports the tool call of the turn: its title, its raw
    /// input and its raw output.
    private static let toolCallUpdate = SessionUpdate.toolCallUpdate(
        ToolCallUpdate(
            toolCallId: toolCallID,
            rawInput: .value(.object(["path": .string(Fixture.toolInput)])),
            rawOutput: .value(.string(Fixture.toolOutput)),
            status: .value(.completed),
            title: .value(Fixture.toolTitle)
        )
    )

    /// The updates of the turn that the agent answers: the tool call, the
    /// answer, and the end of the turn.
    private static let answeredTurnScript = [
        toolCallUpdate,
        agentChunk(text: Fixture.answer),
        idleState(stopReason: .endTurn),
    ]

    /// The permission request that the agent sends in the turn. It is about a
    /// tool call with a title of its own.
    private static let permissionRequest = RequestPermissionRequest(
        options: [
            PermissionOption(
                kind: .rejectOnce,
                name: "Reject",
                optionId: PermissionOptionId(rawValue: "reject-once")
            )
        ],
        sessionId: testSession,
        title: Fixture.permissionTitle,
        subject: .toolCall(
            ToolCallPermissionSubject(
                toolCall: ToolCallUpdate(
                    toolCallId: ToolCallId(rawValue: "content-safety-permission-call"),
                    title: .value(Fixture.permissionToolTitle)
                )
            )
        )
    )

    /// The error that the agent refuses a turn with. Its message and its data
    /// hold fixture strings.
    private static let refusal = RequestError(
        code: .internalError,
        message: Fixture.refusalMessage,
        data: .object(["detail": .string(Fixture.refusalDetail)])
    )

    /// No span, log record or metric of a whole answered turn holds the
    /// prompt, the answer, the tool call, the permission request or the
    /// `cwd` of the turn.
    @MainActor @Test("an answered turn puts no content into telemetry", .timeLimit(.minutes(1)))
    func anAnsweredTurnPutsNoContentIntoTelemetry() async throws {
        try await TelemetryCapture.run(forbidding: Fixture.answeredTurnContent) { context in
            let harness = await TracedSessionHarness(
                prompt: Fixture.prompt,
                cwd: Fixture.workingDirectory,
                script: Self.answeredTurnScript,
                permissionRequest: Self.permissionRequest
            )
            try await harness.runWholeSession()
            await harness.teardown()

            Self.expectEachSignal(in: context)
        }
    }

    /// No span, log record or metric of a turn that the agent refuses holds
    /// the message text or the data of the error.
    @MainActor @Test("a refused turn puts no error text into telemetry", .timeLimit(.minutes(1)))
    func aRefusedTurnPutsNoErrorTextIntoTelemetry() async throws {
        try await TelemetryCapture.run(forbidding: Fixture.refusedTurnContent) { context in
            let harness = await TracedSessionHarness(
                prompt: Fixture.prompt,
                cwd: Fixture.workingDirectory,
                promptError: Self.refusal
            )
            _ = try await harness.session.initialize()
            await #expect(throws: Self.refusal) {
                try await harness.runner.run()
            }
            await harness.session.closeSession(testSession)
            await harness.teardown()

            Self.expectEachSignal(in: context)
        }
    }

    /// Records an issue for each signal that the capture did not see: a
    /// span, a log record or a metric.
    ///
    /// A leak check over empty telemetry finds no leak. This check makes sure
    /// that the leak check read real records.
    ///
    /// - Parameters:
    ///   - context: The capture of the turn.
    ///   - sourceLocation: The source location that each issue names.
    private static func expectEachSignal(
        in context: TelemetryCapture.Context,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(!context.spans.isEmpty, "The capture saw no span.", sourceLocation: sourceLocation)
        #expect(!context.logRecords.isEmpty, "The capture saw no log record.", sourceLocation: sourceLocation)
        #expect(!context.metricRecords.isEmpty, "The capture saw no metric.", sourceLocation: sourceLocation)
    }
}
