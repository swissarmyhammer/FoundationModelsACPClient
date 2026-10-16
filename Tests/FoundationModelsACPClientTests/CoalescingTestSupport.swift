import Foundation
import Observation
import Synchronization

// The shared helpers of the chunk-coalescing and timing tests: a manual clock
// and a manual wall clock that move only when a test advances them, a
// thread-safe mutation counter, an observation change counter, and an event
// wait. No test that uses them reads the wall clock.

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

        /// Returns the distance from this instant to another instant.
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
                    // The sleeper count changed, so a wait for a sleeper
                    // reads it again.
                    TestChangeSignal.post()
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
            TestChangeSignal.post()
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
        TestChangeSignal.post()
    }
}

// MARK: - A manual wall clock

/// A wall clock for tests. The date moves only when a test advances it.
///
/// Give ``now()`` as the `now` parameter of a model, so the model reads this
/// date and not the system date.
final class ManualWallClock: Sendable {
    /// The date at which each manual wall clock starts.
    static let startDate = Date(timeIntervalSinceReferenceDate: 0)

    /// The current date. The mutex is the synchronization for `Sendable`.
    private let date = Mutex(ManualWallClock.startDate)

    /// Gives the current date.
    ///
    /// - Returns: The current date.
    @Sendable func now() -> Date {
        date.withLock { $0 }
    }

    /// Moves the date forward.
    ///
    /// - Parameter interval: The distance to move the date, in seconds.
    func advance(by interval: TimeInterval) {
        date.withLock { $0 += interval }
    }
}

// MARK: - Helpers

/// Counts each observable change of the values that `read` reads.
///
/// The tracker registers again inside each `onChange`, so it counts every
/// change one by one, as SwiftUI would see them with an immediate re-render.
///
/// - Parameters:
///   - read: The reads that the observation tracks.
///   - counter: The change count to increase.
@MainActor
func countChanges(of read: @escaping @MainActor @Sendable () -> Void, into counter: MutationCounter) {
    withObservationTracking(read) {
        counter.increase()
        MainActor.assumeIsolated {
            countChanges(of: read, into: counter)
        }
    }
}

/// A thread-safe mutation counter for observation tests.
final class MutationCounter: Sendable {
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
