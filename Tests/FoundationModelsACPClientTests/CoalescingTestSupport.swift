import Foundation
import Synchronization

// The shared helpers of the chunk-coalescing tests: a manual clock that moves
// only when a test advances it, a thread-safe mutation counter, and a
// cooperative wait. No test that uses them reads the wall clock.

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

/// Yields until the condition is true, or until the yield limit is reached.
///
/// - Parameter condition: The condition to wait for.
@MainActor
func yieldUntil(_ condition: () -> Bool) async {
    var remaining = maxYieldCount
    while remaining > 0, !condition() {
        remaining -= 1
        await Task.yield()
    }
}
