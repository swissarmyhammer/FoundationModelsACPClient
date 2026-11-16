import Foundation
import FoundationModelsACP
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPClient

// The test of a sensitive elicitation. The agent asks for a secret with
// `"sensitive": true` in the `_meta` of `elicitation/create`. The client must
// send the secret to the agent, and must keep it in no other place: no span,
// swift-log record or metric, no line of the connection logger, and no part
// of the connection model or the session model after the answer.
//
// The library logs only through swift-log and `ACPLogger`, and
// `ACPClientTelemetryVocabularyTests` forbids the `os` module in the
// sources. Thus the test captures both sinks at the source, and does not
// read the OSLog store: a host that sends swift-log to OSLog gets only the
// records that the capture saw. A read of the store takes about six seconds.

@Suite("sensitive elicitation")
struct SensitiveElicitationTests {
    /// The secret that the user gives. Each run has a new value, so an old
    /// log line of the process cannot match it.
    private static let secret = "sk-sensitive-\(UUID().uuidString)"

    /// The answer of the user: the secret in the one required "name" field.
    private static let secretContent: JSONValue = .object(["name": .string(secret)])

    /// The session-scoped form elicitation that asks for the secret, with the
    /// sensitive marker in its `_meta`.
    private static let elicitation = CreateElicitationRequest(
        message: "The API key of the server?",
        mode: .form(
            ElicitationFormMode(
                requestedSchema: ElicitationFixtures.nameSchema,
                scope: .session(ElicitationFixtures.sessionScope)
            )
        ),
        meta: .object(["sensitive": .bool(true)])
    )

    @MainActor @Test("the answer to a sensitive elicitation goes only to the agent")
    func theAnswerGoesOnlyToTheAgent() async throws {
        let connectionLog = ThreadSafeBuffer<String>()
        try await TelemetryCapture.run(forbidding: [Self.secret]) { context in
            let harness = await TracedSessionHarness(
                elicitation: Self.elicitation,
                logger: ACPLogger { connectionLog.append($0) }
            )
            defer { await harness.teardown() }
            try await harness.initialize()
            let turn = try await harness.startTurn()
            let pending = try await UserAnswers.firstPendingElicitation(of: turn)
            #expect(pending.request.meta == .object(["sensitive": .bool(true)]))

            turn.session.acceptElicitation(pending.id, content: Self.secretContent)
            try await turn.finish()

            // The secret went to the agent, so the checks below look at a
            // real answer and not at an answer that did not go.
            let response = try #require(harness.elicitationResponses.first)
            #expect(Self.text(of: response).contains(Self.secret))

            #expect(!Self.text(of: harness.model).contains(Self.secret))
            #expect(!Self.text(of: turn.session).contains(Self.secret))

            try await harness.closeTheTurnSession()
            await harness.teardown()
            context.expectEachSignal()
        }
        #expect(connectionLog.elements.allSatisfy { !$0.contains(Self.secret) })
    }

    /// The `dump` text of a value.
    ///
    /// - Parameter value: The value to dump.
    /// - Returns: The text.
    private static func text(of value: some Any) -> String {
        var text = ""
        dump(value, to: &text)
        return text
    }
}
