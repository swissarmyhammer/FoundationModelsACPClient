import Foundation
import FoundationModelsACP
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of the request methods of `SessionModel`: the local pending user
// message of a prompt, its link to the message that the agent inserted, the
// error entries, and the cancel and set-config-option requests. A fake sender
// holds each prompt until the test answers it, so a test puts the echo
// before or after the response.

/// The raw message id that the agent gives the prompted user message.
private let promptedMessage = "prompted-user-1"

/// The message id that the agent gives the prompted user message.
private let promptedMessageId = MessageId(rawValue: promptedMessage)

/// The response that names the prompted user message.
private let promptedResponse = PromptResponse(messageId: promptedMessageId)

/// The text of the prompt.
private let promptText = "Hello agent"

/// The `_meta` field that the tests give a request, as a trace parent does.
private let traceMeta: JSONValue = .object(["traceparent": .string("00-trace-span-01")])

/// The request tests, in one suite so that `swift test --filter
/// SessionModelPromptTests` selects them. A test that waits for a prompt the
/// fake never receives would suspend forever, so the suite has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionModelPromptTests {
    /// The fake sender of the model under test.
    let sender = FakeSessionRequestSender()

    /// Makes the model under test with the fake sender.
    ///
    /// - Parameters:
    ///   - cadence: The coalescing cadence of the model.
    ///   - clock: The clock that schedules the coalesced flushes.
    /// - Returns: The model.
    func makeModel(cadence: Duration = .zero, clock: ManualClock = ManualClock()) -> SessionModel {
        SessionModel(sessionId: testSession, requestSender: sender, coalescingCadence: cadence, clock: clock)
    }

    /// Starts a prompt of the test text, and waits until the fake sender
    /// holds the request.
    ///
    /// - Parameter model: The model that sends the prompt.
    /// - Returns: The task of the prompt call.
    func startPrompt(on model: SessionModel) async -> Task<PromptResponse, any Error> {
        let call = Task { try await model.prompt([textBlock(promptText)]) }
        var received = sender.receivedPrompts.makeAsyncIterator()
        _ = await received.next()
        return call
    }

    /// Gives the user-message objects of a transcript, in order.
    ///
    /// - Parameter model: The model to read.
    /// - Returns: The user-message objects.
    func userMessages(of model: SessionModel) -> [UserMessageEntry] {
        model.transcript.compactMap(\.userMessage)
    }

    // MARK: - The link

    @Test func responseFirstSetsTheMessageIdAndSentState() async throws {
        let model = makeModel()
        let call = await startPrompt(on: model)
        let local = try #require(model.transcript.first?.userMessage)

        sender.answerPrompt(with: promptedResponse)
        let response = try await call.value

        #expect(response == promptedResponse)
        #expect(local.messageId == promptedMessageId)
        #expect(local.sendState == .sent)
    }

    @Test func responseThenEchoKeepsOneLinkedEntryWithTheSameId() async throws {
        let model = makeModel()
        let call = await startPrompt(on: model)
        let local = try #require(model.transcript.first?.userMessage)
        let localID = local.id
        sender.answerPrompt(with: promptedResponse)
        _ = try await call.value

        model.apply(userChunk(text: promptText, message: promptedMessage))

        #expect(model.transcript.count == 1)
        #expect(model.transcript.first?.userMessage === local)
        #expect(local.id == localID)
        #expect(local.origin == .local)
        #expect(local.messageId == promptedMessageId)
        #expect(local.sendState == .sent)
        #expect(local.content == [textBlock(promptText)])
    }

    @Test func echoThenResponseKeepsOneLinkedEntryWithTheSameId() async throws {
        let model = makeModel()
        let call = await startPrompt(on: model)
        let local = try #require(model.transcript.first?.userMessage)
        let localID = local.id

        model.apply(userChunk(text: promptText, message: promptedMessage))
        #expect(model.transcript.count == 1)
        #expect(local.sendState == .pending)

        sender.answerPrompt(with: promptedResponse)
        _ = try await call.value

        #expect(model.transcript.count == 1)
        #expect(model.transcript.first?.userMessage === local)
        #expect(local.id == localID)
        #expect(local.messageId == promptedMessageId)
        #expect(local.sendState == .sent)
    }

    @Test func echoChunksAfterTheLinkChangeTheLocalEntry() async throws {
        let model = makeModel()
        let call = await startPrompt(on: model)
        let local = try #require(model.transcript.first?.userMessage)
        model.apply(userChunk(text: "Hello ", message: promptedMessage))
        sender.answerPrompt(with: promptedResponse)
        _ = try await call.value

        model.apply(userChunk(text: "agent", message: promptedMessage))

        #expect(model.transcript.count == 1)
        #expect(local.content == [textBlock("Hello "), textBlock("agent")])
    }

    @Test func echoAfterBufferedChunksLinksTheLocalEntry() async throws {
        let clock = ManualClock()
        let model = makeModel(cadence: SessionModelFixtures.bufferedCadence, clock: clock)
        let call = await startPrompt(on: model)
        let local = try #require(model.transcript.first?.userMessage)
        sender.answerPrompt(with: promptedResponse)
        _ = try await call.value

        model.apply(agentChunk(text: "Thinking"))
        model.apply(userChunk(text: promptText, message: promptedMessage))
        model.flushPendingChunks()

        #expect(userMessages(of: model).count == 1)
        #expect(userMessages(of: model).first === local)
        #expect(local.messageId == promptedMessageId)
    }

    @Test func echoBeforeTheResponseThroughTheBufferLinksTheLocalEntry() async throws {
        let clock = ManualClock()
        let model = makeModel(cadence: SessionModelFixtures.bufferedCadence, clock: clock)
        let call = await startPrompt(on: model)
        let local = try #require(model.transcript.first?.userMessage)

        model.apply(agentChunk(text: "Thinking"))
        model.apply(userChunk(text: promptText, message: promptedMessage))
        sender.answerPrompt(with: promptedResponse)
        _ = try await call.value
        model.flushPendingChunks()

        #expect(userMessages(of: model).count == 1)
        #expect(userMessages(of: model).first === local)
        #expect(local.sendState == .sent)
    }

    @Test func echoOfAnotherMessageAppearsWhenTheResponseNamesAnotherMessage() async throws {
        let model = makeModel()
        let call = await startPrompt(on: model)
        let local = try #require(model.transcript.first?.userMessage)

        model.apply(userChunk(text: "From elsewhere", message: "other-user-1"))
        sender.answerPrompt(with: promptedResponse)
        _ = try await call.value

        #expect(userMessages(of: model).count == 2)
        #expect(userMessages(of: model).first === local)
        let other = try #require(userMessages(of: model).last)
        #expect(other.id == .wire(.userMessage(MessageId(rawValue: "other-user-1"))))
        #expect(other.content == [textBlock("From elsewhere")])
    }

    @Test func pendingEntryExistsBeforeTheSenderReceivesTheRequest() async throws {
        let model = makeModel()
        let seen = Mutex<[SendState]>([])
        sender.observePrompts { _ in
            seen.withLock { $0 = model.transcript.compactMap(\.userMessage).map(\.sendState) }
        }

        let call = await startPrompt(on: model)

        #expect(seen.withLock { $0 } == [.pending])
        let local = try #require(model.transcript.first?.userMessage)
        #expect(local.origin == .local)
        #expect(local.messageId == nil)
        sender.answerPrompt(with: promptedResponse)
        _ = try await call.value
    }

    @Test func promptSendsTheContentSessionAndMetaUnchanged() async throws {
        let model = makeModel()
        let call = Task { try await model.prompt([textBlock(promptText)], meta: traceMeta) }
        var received = sender.receivedPrompts.makeAsyncIterator()
        let request = try #require(await received.next())

        #expect(request == PromptRequest(prompt: [textBlock(promptText)], sessionId: testSession, meta: traceMeta))
        sender.answerPrompt(with: promptedResponse)
        _ = try await call.value
    }

    // MARK: - Failure

    @Test func failedPromptMarksTheEntryFailedAndAppendsAnErrorEntry() async throws {
        let model = makeModel()
        let call = await startPrompt(on: model)
        let local = try #require(model.transcript.first?.userMessage)
        let refusal = RequestError(code: .invalidParams, message: "Bad prompt", data: .object(["field": .string("prompt")]))

        sender.failPrompt(with: refusal)

        await #expect(throws: refusal) { try await call.value }
        #expect(local.sendState == .failed)
        #expect(local.messageId == nil)
        let error = try #require(model.transcript.last?.error)
        #expect(model.transcript.count == 2)
        #expect(error.origin == .local)
        #expect(error.code == .invalidParams)
        #expect(error.message == "Bad prompt")
        #expect(error.data == .object(["field": .string("prompt")]))
    }

    @Test func closedConnectionGivesAnInternalErrorEntryThatNamesTheCause() async throws {
        let model = makeModel()
        let call = await startPrompt(on: model)

        sender.failPrompt(with: ConnectionError.closed)

        await #expect(throws: ConnectionError.closed) { try await call.value }
        let error = try #require(model.transcript.last?.error)
        #expect(error.code == .internalError)
        #expect(error.data == .object(["connectionError": .string("closed")]))
    }

    @Test func echoThatAFailedPromptDidNotClaimAppears() async throws {
        let model = makeModel()
        let call = await startPrompt(on: model)
        model.apply(userChunk(text: "From elsewhere", message: "other-user-1"))

        sender.failPrompt(with: ConnectionError.closed)
        await #expect(throws: ConnectionError.closed) { try await call.value }

        #expect(userMessages(of: model).count == 2)
        #expect(userMessages(of: model).last?.id == .wire(.userMessage(MessageId(rawValue: "other-user-1"))))
    }

    @Test func appendErrorAddsALocalErrorEntry() throws {
        let model = makeModel()

        model.appendError(code: .authenticationRequired, message: "Log in first", data: .string("login"))

        let error = try #require(model.transcript.first?.error)
        #expect(error.origin == .local)
        #expect(error.code == .authenticationRequired)
        #expect(error.message == "Log in first")
        #expect(error.data == .string("login"))
    }

    // MARK: - Cancel and configuration

    @Test func cancelSendsTheSessionAndMetaUnchanged() async throws {
        let model = makeModel()

        try await model.cancel(meta: traceMeta)

        #expect(sender.cancelNotifications == [CancelSessionNotification(sessionId: testSession, meta: traceMeta)])
    }

    @Test func setConfigOptionSendsTheRequestUnchanged() async throws {
        let model = makeModel()
        let request = SetSessionConfigOptionRequest(
            configId: SessionConfigId(rawValue: "mode"),
            sessionId: testSession,
            value: .id(SessionConfigValueId(rawValue: "fast")),
            meta: traceMeta
        )

        try await model.setConfigOption(request)

        #expect(sender.configOptionRequests == [request])
    }
}
