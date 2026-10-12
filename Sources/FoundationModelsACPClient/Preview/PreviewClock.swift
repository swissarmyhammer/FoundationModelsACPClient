/// A clock whose time never moves, for a preview model.
///
/// A preview model reads this clock for the arrival time of each notice, so
/// a preview shows the same times each time it runs. A sleep to a deadline
/// that is not now never ends: it waits until its task is cancelled, and then
/// throws `CancellationError`. A preview model has the `.zero` coalescing
/// cadence, so it never sleeps on this clock.
struct PreviewClock: Clock {
    /// The one instant of the clock.
    struct Instant: InstantProtocol {
        /// The offset from the start of the clock. Only ``advanced(by:)``
        /// makes an instant that is not the start.
        var offset: Duration = .zero

        /// Gives the instant that is `duration` after this instant.
        ///
        /// - Parameter duration: The distance to move.
        /// - Returns: The moved instant.
        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        /// Gives the distance from this instant to another instant.
        ///
        /// - Parameter other: The target instant.
        /// - Returns: The distance.
        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        /// Tells whether one instant comes before another.
        ///
        /// - Parameters:
        ///   - lhs: The first instant.
        ///   - rhs: The second instant.
        /// - Returns: `true` when `lhs` comes before `rhs`.
        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    /// The current time: always the start of the clock.
    var now: Instant {
        Instant()
    }

    /// The smallest step of the clock.
    var minimumResolution: Duration {
        .zero
    }

    /// Returns at once for a deadline that is now or earlier. For a later
    /// deadline, waits until the task is cancelled, because the time never
    /// gets there.
    ///
    /// - Parameters:
    ///   - deadline: The instant to wait for.
    ///   - tolerance: Ignored. The clock never moves.
    /// - Throws: `CancellationError` when the task is cancelled before the
    ///   deadline.
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        guard now < deadline else { return }
        try await CancellationWait.untilCancelled()
    }
}
