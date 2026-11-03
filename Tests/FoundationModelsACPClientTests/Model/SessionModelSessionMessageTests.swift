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

/// Makes a `session_message` update with the given fields.
private func upsert(
    content: PatchField<[ContentBlock]> = .unchanged,
    senderSessionId: PatchField<SessionId> = .unchanged,
    recipientSessionId: PatchField<SessionId> = .unchanged,
    senderMessageId: PatchField<MessageId> = .unchanged,
    recipientMessageId: PatchField<MessageId> = .unchanged
) -> SessionUpdate {
    .sessionMessage(
        SessionMessage(
            messageId: messageId,
            content: content,
            recipientMessageId: recipientMessageId,
            recipientSessionId: recipientSessionId,
            senderMessageId: senderMessageId,
            senderSessionId: senderSessionId
        )
    )
}

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
}
