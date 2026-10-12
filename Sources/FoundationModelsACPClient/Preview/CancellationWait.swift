/// The wait of a preview for a time or an answer that never comes.
///
/// ``PreviewClock`` waits here for a deadline that its time never gets to,
/// and ``PreviewSessionRequestSender`` waits here for a prompt that it never
/// answers.
enum CancellationWait {
    /// Suspends the calling task until it is cancelled.
    ///
    /// A task that is already cancelled does not suspend.
    ///
    /// - Throws: `CancellationError`, always, when the task is cancelled.
    static func untilCancelled() async throws -> Never {
        let (never, continuation) = AsyncStream<Never>.makeStream()
        // The iteration of an `AsyncStream` ends when the task is cancelled.
        // No element ever comes, so only a cancel ends it.
        for await _ in never {}
        // This use keeps the continuation, and thus the stream, open for the
        // whole iteration.
        continuation.finish()
        throw CancellationError()
    }
}
