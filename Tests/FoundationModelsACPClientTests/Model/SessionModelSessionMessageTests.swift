import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the inter-session message entry of `SessionModel`. The
// unstable `session_message` and `session_message_chunk` updates go through
// the merge engine, and land in one `SessionMessageEntry` object of the
// transcript of the session that received them.

/// The message id of the test message.
private let messageId = MessageId(rawValue: "msg-1")

/// The engine identity of the test message.
private let messageEntryID = TranscriptEntry.ID.wire(.sessionMessage(messageId))

/// The session that sent the test message.
private let senderSession = SessionId(rawValue: "sender")

/// The session that receives the test message.
private let recipientSession = SessionId(rawValue: "recipient")

/// The id of the same message in the transcript of the sender.
private let senderMessage = MessageId(rawValue: "sender-msg")

/// The id of the same message in the transcript of the recipient.
private let recipientMessage = MessageId(rawValue: "recipient-msg")

/// The title of the session that sent the test message.
private let senderTitle = "Planner"

/// The agent of the session that sent the test message.
private let senderAgent = "claude"

/// The working folder of the session that sent the test message.
private let senderFolder = "/work/planner"

/// Makes a `session_message` update with the given fields.
private func upsert(
    content: PatchField<[ContentBlock]> = .unchanged,
    senderSessionId: PatchField<SessionId> = .unchanged,
    recipientSessionId: PatchField<SessionId> = .unchanged,
    senderMessageId: PatchField<MessageId> = .unchanged,
    recipientMessageId: PatchField<MessageId> = .unchanged,
    meta: PatchField<JSONValue> = .unchanged
) -> SessionUpdate {
    .sessionMessage(
        SessionMessage(
            messageId: messageId,
            content: content,
            recipientMessageId: recipientMessageId,
            recipientSessionId: recipientSessionId,
            senderMessageId: senderMessageId,
            senderSessionId: senderSessionId,
            meta: meta
        )
    )
}

/// Makes a `_meta` value that holds `_meta.sah.message` with the given sender.
///
/// - Parameter sender: The sender of the message.
/// - Returns: The `_meta` value.
/// - Throws: `EncodingError` when the sender cannot be encoded.
private func sahMeta(_ sender: SAH.SessionMessage.Sender) throws -> JSONValue {
    try SAH.SessionMessage(sender: sender).inject(into: nil)
}

/// A sender of kind `user`, through the session with the given title.
///
/// - Parameter title: The title of the session of the user.
/// - Returns: The sender.
private func userSender(title: String = senderTitle) -> SAH.SessionMessage.Sender {
    SAH.SessionMessage.Sender(kind: .user, sessionId: senderSession, title: title)
}

/// A sender of kind `session`, with each field set.
private let sessionSender = SAH.SessionMessage.Sender(
    kind: .session,
    sessionId: senderSession,
    title: senderTitle,
    agent: senderAgent,
    cwd: senderFolder
)

/// A `_meta` value that has no `sah.message` member.
private let otherMeta = JSONValue.object(["trace": .string("t-1")])

/// The inter-session message tests, in one suite so that `swift test
/// --filter SessionModelSessionMessageTests` selects them.
@MainActor
struct SessionModelSessionMessageTests {
    @Test func aSessionMessageAddsOneEntryAtTheEnd() throws {
        let model = SessionModelFixtures.immediateModel()

        model.apply(upsert(content: .value([textBlock("Hello")])))

        let entry = try #require(model.transcript.last?.sessionMessage)
        #expect(model.transcript.map(\.id) == [messageEntryID])
        #expect(entry.messageId == messageId)
        #expect(entry.content == [textBlock("Hello")])
        #expect(entry.origin == .wire)
    }

    @Test func theEntryHoldsTheSenderAndTheRecipient() throws {
        let model = SessionModelFixtures.immediateModel()

        model.apply(
            upsert(
                senderSessionId: .value(senderSession),
                recipientSessionId: .value(recipientSession),
                senderMessageId: .value(senderMessage),
                recipientMessageId: .value(recipientMessage)
            )
        )

        let entry = try #require(model.transcript.last?.sessionMessage)
        #expect(entry.senderSessionId == senderSession)
        #expect(entry.recipientSessionId == recipientSession)
        #expect(entry.senderMessageId == senderMessage)
        #expect(entry.recipientMessageId == recipientMessage)
    }

    @Test func aChunkAppendsToTheContentOfTheSameObject() throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(upsert(content: .value([textBlock("Hello")])))
        let entry = try #require(model.transcript.first?.sessionMessage)

        model.apply(.sessionMessageChunk(SessionMessageChunk(content: textBlock(" world"), messageId: messageId)))

        #expect(model.transcript.first?.sessionMessage === entry)
        #expect(entry.content == [textBlock("Hello"), textBlock(" world")])
    }

    @Test func aLaterUpsertWithNullClearsTheSender() throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(upsert(senderSessionId: .value(senderSession)))
        let entry = try #require(model.transcript.first?.sessionMessage)

        model.apply(upsert(senderSessionId: .cleared))

        #expect(entry.senderSessionId == nil)
    }

    @Test func aContentChangeWritesOnlyTheContent() throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(upsert(content: .value([textBlock("a")]), senderSessionId: .value(senderSession)))
        let entry = try #require(model.transcript.first?.sessionMessage)

        let fired = observationFires {
            _ = (entry.senderSessionId, entry.recipientSessionId, entry.meta)
        } during: {
            model.apply(upsert(content: .value([textBlock("b")])))
        }

        #expect(!fired)
    }

    @Test func aUserSenderGivesTheKindTheSessionAndTheTitle() throws {
        let model = SessionModelFixtures.immediateModel()

        model.apply(upsert(meta: .value(try sahMeta(userSender()))))

        let entry = try #require(model.transcript.last?.sessionMessage)
        #expect(entry.sahMessage?.sender == userSender())
    }

    @Test func aSessionSenderGivesEachFieldOfTheSender() throws {
        let model = SessionModelFixtures.immediateModel()

        model.apply(upsert(meta: .value(try sahMeta(sessionSender))))

        let entry = try #require(model.transcript.last?.sessionMessage)
        #expect(entry.sahMessage?.sender == sessionSender)
    }

    @Test func anEntryWithNoMetaGivesNoSAHMessage() throws {
        let model = SessionModelFixtures.immediateModel()

        model.apply(upsert(content: .value([textBlock("Hello")])))

        let entry = try #require(model.transcript.last?.sessionMessage)
        #expect(entry.sahMessage == nil)
    }

    @Test func aMetaWithNoSAHMessageGivesNoSAHMessage() throws {
        let model = SessionModelFixtures.immediateModel()

        model.apply(upsert(meta: .value(otherMeta)))

        let entry = try #require(model.transcript.last?.sessionMessage)
        #expect(entry.sahMessage == nil)
    }

    @Test func aSecondUpsertGivesTheNewestSender() throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(upsert(meta: .value(try sahMeta(userSender(title: "First")))))

        model.apply(upsert(meta: .value(try sahMeta(userSender(title: "Second")))))

        let entry = try #require(model.transcript.last?.sessionMessage)
        #expect(entry.sahMessage?.sender.title == "Second")
    }

    @Test func aUserMessageWithASAHMessageGivesTheTypedValue() throws {
        let entry = UserMessageEntry(content: [textBlock("Hello")], meta: try sahMeta(sessionSender))

        #expect(entry.sahMessage?.sender == sessionSender)
    }

    @Test func aUserMessageWithNoMetaGivesNoSAHMessage() {
        let entry = UserMessageEntry(content: [textBlock("Hello")], meta: nil)

        #expect(entry.sahMessage == nil)
    }
}
