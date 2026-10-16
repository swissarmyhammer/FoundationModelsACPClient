import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of `SessionModel.mailDeliveryPause`: the `_mail_delivery_paused`
// extension update of the FoundationModelsACPAgent session (ACPAgent
// d30f8cd) sets it, and adds no transcript entry. A prompt of this client and
// each folded user message clear it. A replay keeps it until it gives a later
// user message, and the close keeps it.

/// The limit in force that the test pause gives.
private let pauseLimit = 3

/// The text for a person that the test pause gives.
private let pauseMessage = "The session holds 2 run results until the next message."

/// The held results of the test pause, in queue order.
private let heldMail = [
    HeldMail(tool: "build", op: "run", completionToken: "token-1"),
    HeldMail(tool: "test", op: "run", completionToken: "token-2"),
]

/// The pause that the test update gives.
private let expectedPause = MailDeliveryPause(
    limit: pauseLimit,
    heldCount: heldMail.count,
    heldMail: heldMail,
    message: pauseMessage
)

/// Makes the members of a `_mail_delivery_paused` update, as ACPAgent sends
/// them.
///
/// - Returns: The members.
private func pauseMembers() -> [String: JSONValue] {
    [
        "limit": .number(Double(pauseLimit)),
        "heldCount": .number(Double(heldMail.count)),
        "heldMail": .array(heldMail.map { mail in
            .object([
                "tool": .string(mail.tool),
                "op": .string(mail.op),
                "completionToken": .string(mail.completionToken),
            ])
        }),
        "message": .string(pauseMessage),
    ]
}

/// Makes a `_mail_delivery_paused` update.
///
/// - Parameters:
///   - members: The members of the payload.
///   - kind: The `sessionUpdate` value.
/// - Returns: The update.
private func pauseUpdate(
    _ members: [String: JSONValue] = pauseMembers(),
    kind: String = "_mail_delivery_paused"
) -> SessionUpdate {
    .unknown(kind, .object(members))
}

/// The mail pause tests, in one suite so that `swift test --filter
/// SessionModelMailPauseTests` selects them.
@MainActor
@Suite
struct SessionModelMailPauseTests {
    // MARK: - Decode

    @Test func aFullPayloadDecodesEachMemberInOrder() {
        let pause = MailDeliveryPause.decode(pauseUpdate())

        #expect(pause == expectedPause)
        #expect(pause?.heldMail.map(\.id) == ["token-1", "token-2"])
    }

    @Test(arguments: ["limit", "heldCount", "heldMail", "message"])
    func aMissingMemberMakesTheModelIgnoreTheUpdate(member: String) {
        let model = SessionModelFixtures.immediateModel()
        var members = pauseMembers()
        members[member] = nil

        model.apply(pauseUpdate(members))

        #expect(model.mailDeliveryPause == nil)
        #expect(model.transcript.isEmpty)
    }

    @Test func aMemberOfTheWrongTypeMakesTheModelIgnoreTheUpdate() {
        let model = SessionModelFixtures.immediateModel()
        let wrongMembers: [[String: JSONValue]] = [
            pauseMembers().merging(["limit": .number(2.5)]) { $1 },
            pauseMembers().merging(["heldCount": .string("2")]) { $1 },
            pauseMembers().merging(["message": .number(1)]) { $1 },
            pauseMembers().merging(["heldMail": .array([.object(["tool": .string("build")])])]) { $1 },
        ]

        model.applyEach(wrongMembers.map { pauseUpdate($0) })

        #expect(model.mailDeliveryPause == nil)
        #expect(model.transcript.isEmpty)
    }

    @Test func anUpdateOfAnotherKindGoesToTheEngineAsBefore() {
        let model = SessionModelFixtures.immediateModel()

        model.apply(pauseUpdate(kind: "_mail_delivery_pausedX"))

        #expect(model.mailDeliveryPause == nil)
        #expect(model.transcript.count == 1)
    }

    // MARK: - Set

    @Test func thePauseUpdateSetsThePauseAndFiresTheObservation() {
        let model = SessionModelFixtures.immediateModel()

        let fires = observationFires(reading: { _ = model.mailDeliveryPause }) {
            model.apply(pauseUpdate())
        }

        #expect(fires)
        #expect(model.mailDeliveryPause == expectedPause)
        #expect(model.transcript.isEmpty)
    }

    @Test func aSecondPauseUpdateReplacesThePause() {
        let model = SessionModelFixtures.immediateModel()
        model.apply(pauseUpdate())
        var members = pauseMembers()
        members["heldCount"] = .number(1)
        members["heldMail"] = .array([.object([
            "tool": .string("lint"), "op": .string("run"), "completionToken": .string("token-3"),
        ])])

        model.apply(pauseUpdate(members))

        #expect(model.mailDeliveryPause?.heldCount == 1)
        #expect(model.mailDeliveryPause?.heldMail.map(\.completionToken) == ["token-3"])
    }

    // MARK: - Clear

    @Test func aPromptClearsThePauseWhenItGoesOutAndBeforeTheAnswer() async throws {
        let sender = FakeSessionRequestSender()
        let model = SessionModelFixtures.makeModel(sender: sender)
        model.apply(pauseUpdate())

        let call = await model.startPrompt("go on", heldBy: sender)

        #expect(model.mailDeliveryPause == nil)
        sender.answerPrompt(with: PromptResponse(messageId: MessageId(rawValue: "user-1")))
        _ = try await call.value
    }

    @Test func aPromptThatFailsAfterItWentOutAlsoClearsThePause() async {
        let sender = FakeSessionRequestSender()
        let model = SessionModelFixtures.makeModel(sender: sender)
        model.apply(pauseUpdate())
        let call = await model.startPrompt("go on", heldBy: sender)

        sender.failPrompt(with: ConnectionError.closed)

        await #expect(throws: ConnectionError.closed) { try await call.value }
        #expect(model.mailDeliveryPause == nil)
    }

    @Test func aUserMessageOfAnotherClientClearsThePause() {
        let model = SessionModelFixtures.immediateModel()
        model.apply(pauseUpdate())

        model.apply(userChunk(text: "from another client", message: "other-user-1"))

        #expect(model.mailDeliveryPause == nil)
    }

    @Test func aWholeUserMessageClearsThePause() {
        let model = SessionModelFixtures.immediateModel()
        model.apply(pauseUpdate())

        model.apply(.userMessage(UserMessage(messageId: MessageId(rawValue: "user-2"), content: .value([textBlock("next")]))))

        #expect(model.mailDeliveryPause == nil)
    }

    @Test func otherUpdatesKeepThePause() {
        let model = SessionModelFixtures.immediateModel()
        model.apply(pauseUpdate())

        model.applyEach([agentChunk(text: "answer"), idleState(stopReason: .endTurn)])

        #expect(model.mailDeliveryPause == expectedPause)
    }

    // MARK: - Replay and close

    @Test func aReplayFromTheStartSetsThePauseAgain() {
        let model = SessionModelFixtures.immediateModel()
        model.applyEach([userChunk(text: "first"), pauseUpdate()])

        model.beginReplay(replayFrom: SessionModelFixtures.replayFromStart)
        model.applyEach([userChunk(text: "first"), pauseUpdate()])
        model.endReplay(succeeded: true)

        #expect(model.mailDeliveryPause == expectedPause)
    }

    @Test func aReplayWithALaterUserMessageClearsThePause() {
        let model = SessionModelFixtures.immediateModel()
        model.apply(pauseUpdate())

        model.beginReplay(replayFrom: SessionModelFixtures.replayFromStart)
        model.applyEach([pauseUpdate(), userChunk(text: "later", message: "user-2")])
        model.endReplay(succeeded: true)

        #expect(model.mailDeliveryPause == nil)
    }

    @Test func aResumeWithNoReplayKeepsThePause() {
        let model = SessionModelFixtures.immediateModel()
        model.apply(pauseUpdate())

        model.beginReplay(replayFrom: nil)
        model.endReplay(succeeded: true)

        #expect(model.mailDeliveryPause == expectedPause)
    }

    @Test func theCloseKeepsThePause() {
        let model = SessionModelFixtures.immediateModel()
        model.apply(pauseUpdate())

        model.markClosed()

        #expect(model.mailDeliveryPause == expectedPause)
    }
}
