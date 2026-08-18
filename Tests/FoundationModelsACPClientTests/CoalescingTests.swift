import Foundation
import FoundationModelsACP
import Observation
import Synchronization
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

/// The highest number of cooperative yields a test waits for the scheduled
/// flush task to run. The wait is cooperative, so no test reads the wall
/// clock.
private let maxYieldCount = 10_000

// MARK: - A manual clock

/// A clock for tests. Time moves only when a test advances it.
///
/// `sleep(until:tolerance:)` suspends until the clock reaches the deadline,
/// or until the task is cancelled.
final class ManualClock: Clock, Sendable {
    /// One point of manual time, as an offset from the clock start.
    struct Instant: InstantProtocol, Hashable {
        /// The offset from the clock start.
        var offset: Duration = .zero

        /// Returns the instant that is `duration` after this instant.
        ///
        /// - Parameter duration: The distance to move.
        /// - Returns: The moved instant.
        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        /// Returns the distance from this instant to an other instant.
        ///
        /// - Parameter other: The target instant.
        /// - Returns: The distance.
        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    /// One suspended sleeper.
    private struct Sleeper {
        /// The instant at which the sleeper must resume.
        let deadline: Instant

        /// The continuation that resumes the sleeper.
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// The whole mutable state of the clock, held under one mutex.
    private struct State {
        /// The current manual time.
        var now = Instant()

        /// The suspended sleepers, keyed by token.
        var sleepers: [Int: Sleeper] = [:]

        /// The tokens that were cancelled before their sleeper registered.
        var cancelledTokens: Set<Int> = []

        /// The token for the next sleeper.
        var nextToken = 0
    }

    /// The clock state. The mutex is the synchronization for `Sendable`.
    private let state = Mutex(State())

    /// The current manual time.
    var now: Instant {
        state.withLock { $0.now }
    }

    /// The number of suspended sleepers. A test waits for a sleeper before
    /// it advances the clock, so the advance always reaches the sleeper.
    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// The smallest step this clock can represent.
    var minimumResolution: Duration {
        .zero
    }

    /// Suspends until the clock reaches `deadline` or the task is cancelled.
    ///
    /// - Parameters:
    ///   - deadline: The instant at which to resume.
    ///   - tolerance: Ignored. The manual clock is exact.
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let token = state.withLock { locked in
            let token = locked.nextToken
            locked.nextToken += 1
            return token
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                enum Readiness {
                    case wait
                    case resume
                    case cancelled
                }
                let readiness = state.withLock { locked -> Readiness in
                    if locked.cancelledTokens.remove(token) != nil {
                        return .cancelled
                    }
                    if deadline <= locked.now {
                        return .resume
                    }
                    locked.sleepers[token] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch readiness {
                case .wait:
                    break
                case .resume:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { locked -> Sleeper? in
                guard let sleeper = locked.sleepers.removeValue(forKey: token) else {
                    locked.cancelledTokens.insert(token)
                    return nil
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward and resumes each sleeper whose deadline is
    /// reached.
    ///
    /// - Parameter duration: The distance to move the clock.
    func advance(by duration: Duration) {
        let due = state.withLock { locked -> [Sleeper] in
            locked.now = locked.now.advanced(by: duration)
            let dueTokens = locked.sleepers.filter { $0.value.deadline <= locked.now }.map(\.key)
            return dueTokens.compactMap { locked.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

// MARK: - Helpers

/// A thread-safe mutation counter for observation tests.
private final class MutationCounter: Sendable {
    /// The protected count.
    private let count = Mutex(0)

    /// The current count.
    var value: Int {
        count.withLock { $0 }
    }

    /// Increases the count by one.
    func increase() {
        count.withLock { $0 += 1 }
    }
}

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

/// Yields until the condition is true, or until the yield limit is reached.
///
/// - Parameter condition: The condition to wait for.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    var remaining = maxYieldCount
    while remaining > 0, !condition() {
        remaining -= 1
        await Task.yield()
    }
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

    await waitUntil { clock.sleeperCount > 0 }
    clock.advance(by: testCadence)
    await waitUntil { !state.messageContent(for: messageID).isEmpty }

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
