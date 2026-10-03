import Foundation
import FoundationModelsACP
import Observation
import Testing

@testable import FoundationModelsACPClient

// These tests measure the chunk coalescing of `ACPSessionState`. A manual
// clock controls the cadence, so no test reads the wall clock.

/// The number of rapid chunks that the mutation-count test sends.
private let rapidChunkCount = 200

/// The highest permitted mutation count for the rapid-chunk test. The count
/// must be far under `rapidChunkCount`, because coalescing is the point.
private let coalescedMutationLimit = 20

/// The test cadence, in milliseconds.
private let testCadenceMilliseconds = 40

/// The cadence that these tests give the client under test.
private let testCadence: Duration = .milliseconds(testCadenceMilliseconds)

/// Applies one update to the client for the test session, with no flush.
///
/// - Parameters:
///   - update: The update to apply.
///   - client: The client under test.
@MainActor
private func send(_ update: SessionUpdate, to client: SwiftUIACPClient) async {
    await client.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
}

/// Counts each observable mutation of the coalesced session properties.
///
/// The tracker registers again inside each `onChange`, so it counts every
/// mutation of the tracked properties, one by one, as SwiftUI would see them
/// with an immediate re-render.
///
/// - Parameters:
///   - state: The session state to observe.
///   - messageID: The message whose content the tracker reads.
///   - counter: The mutation count to increase.
@MainActor
private func trackMutations(of state: ACPSessionState, messageID: MessageId, counter: MutationCounter) {
    withObservationTracking {
        _ = state.entries
        _ = state.inFlightAgentMessageID
        _ = state.inFlightThoughtID
        _ = state.messageContent(for: messageID)
    } onChange: {
        counter.increase()
        MainActor.assumeIsolated {
            trackMutations(of: state, messageID: messageID, counter: counter)
        }
    }
}

/// Returns the concatenated text of one message.
///
/// - Parameters:
///   - state: The session state to read.
///   - id: The message id.
/// - Returns: The text of all text blocks, joined in order.
@MainActor
private func joinedText(of state: ACPSessionState, for id: MessageId) -> String {
    state.messageContent(for: id)
        .compactMap { block in
            guard case .text(let text) = block else { return nil }
            return text.text
        }
        .joined()
}

// MARK: - Mutation count

@MainActor @Test func rapidChunksCauseFarFewerObservableMutationsThanChunks() async {
    let clock = ManualClock()
    let client = SwiftUIACPClient(coalescingCadence: testCadence, clock: clock)
    let state = client.session(for: testSession)
    let messageID = MessageId(rawValue: "agent-1")
    let mutations = MutationCounter()
    trackMutations(of: state, messageID: messageID, counter: mutations)

    for index in 0..<rapidChunkCount {
        await send(agentChunk(text: "token-\(index) "), to: client)
    }
    await send(idleState(stopReason: .endTurn), to: client)

    #expect(mutations.value < coalescedMutationLimit)
    #expect(state.messageContent(for: messageID).count == rapidChunkCount)
}

// MARK: - Cadence

@MainActor @Test func bufferedChunksFlushWhenTheCadenceElapses() async {
    let clock = ManualClock()
    let client = SwiftUIACPClient(coalescingCadence: testCadence, clock: clock)
    let state = client.session(for: testSession)
    let messageID = MessageId(rawValue: "agent-1")

    await send(agentChunk(text: "one "), to: client)
    await send(agentChunk(text: "two"), to: client)
    #expect(state.messageContent(for: messageID).isEmpty)

    await yieldUntil { clock.sleeperCount > 0 }
    clock.advance(by: testCadence)
    await yieldUntil { !state.messageContent(for: messageID).isEmpty }

    #expect(joinedText(of: state, for: messageID) == "one two")
    #expect(state.entries == [.agentMessage(messageID)])
    #expect(state.inFlightAgentMessageID == messageID)
}

// MARK: - Turn end

@MainActor @Test func aTurnEndFlushesTheBufferedRemainderSynchronously() async {
    let clock = ManualClock()
    let client = SwiftUIACPClient(coalescingCadence: testCadence, clock: clock)
    let state = client.session(for: testSession)
    let messageID = MessageId(rawValue: "agent-1")

    await send(agentChunk(text: "partial "), to: client)
    await send(agentChunk(text: "tail"), to: client)
    #expect(state.messageContent(for: messageID).isEmpty)

    // The clock never moves, so only the turn end can flush the buffer.
    await send(idleState(stopReason: .endTurn), to: client)

    #expect(joinedText(of: state, for: messageID) == "partial tail")
    #expect(state.turnState == .idle)
}

// MARK: - Interleaving

@MainActor @Test func interleavedMessageAndThoughtChunksCoalesceIntoTheirOwnTargets() async {
    let clock = ManualClock()
    let client = SwiftUIACPClient(coalescingCadence: testCadence, clock: clock)
    let state = client.session(for: testSession)
    let messageID = MessageId(rawValue: "agent-1")
    let thoughtID = MessageId(rawValue: "thought-1")

    await send(thoughtChunk(text: "think-a "), to: client)
    await send(agentChunk(text: "say-a "), to: client)
    await send(thoughtChunk(text: "think-b"), to: client)
    await send(agentChunk(text: "say-b"), to: client)
    await send(idleState(stopReason: .endTurn), to: client)

    #expect(joinedText(of: state, for: thoughtID) == "think-a think-b")
    #expect(joinedText(of: state, for: messageID) == "say-a say-b")
    #expect(state.entries == [.agentThought(thoughtID), .agentMessage(messageID)])
    #expect(state.inFlightThoughtID == thoughtID)
    #expect(state.inFlightAgentMessageID == messageID)
}

// MARK: - Concatenation equality

@MainActor @Test func finalTextEqualsThePlainConcatenationOfAllChunks() async {
    let clock = ManualClock()
    let client = SwiftUIACPClient(coalescingCadence: testCadence, clock: clock)
    let state = client.session(for: testSession)
    let messageID = MessageId(rawValue: "agent-1")
    let chunks = ["Hé", "llo,  ", "\n\t", "👋🏽 ", "cafe\u{301}", "  ", "end."]

    for chunk in chunks {
        await send(agentChunk(text: chunk), to: client)
    }
    await send(idleState(stopReason: .endTurn), to: client)

    #expect(joinedText(of: state, for: messageID) == chunks.joined())
    #expect(state.messageContent(for: messageID).count == chunks.count)
}

// MARK: - Connection close

@MainActor @Test func aConnectionCloseFlushesEveryBufferedSession() async {
    let clock = ManualClock()
    let client = SwiftUIACPClient(coalescingCadence: testCadence, clock: clock)
    let otherSession = SessionId(rawValue: "session-2")
    let messageID = MessageId(rawValue: "agent-1")
    let otherMessageID = MessageId(rawValue: "agent-2")
    client.connectionState = .connected

    await send(agentChunk(text: "left open"), to: client)
    await client.sessionUpdate(
        UpdateSessionNotification(
            sessionId: otherSession,
            update: agentChunk(text: "also open", message: "agent-2")
        )
    )
    #expect(client.session(for: testSession).messageContent(for: messageID).isEmpty)

    // The clock never moves, so only the connection close can flush.
    client.connectionState = .disconnected

    #expect(joinedText(of: client.session(for: testSession), for: messageID) == "left open")
    #expect(joinedText(of: client.session(for: otherSession), for: otherMessageID) == "also open")
}
