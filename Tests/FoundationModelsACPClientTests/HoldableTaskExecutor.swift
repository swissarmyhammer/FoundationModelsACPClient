import Dispatch

/// A task executor whose jobs a test can hold back, and then let through.
///
/// A test runs an operation under `withTaskExecutorPreference(_:operation:)`
/// with this executor. Each nonisolated part of that operation then runs on
/// the serial queue of the executor. While the test holds the executor, the
/// queue runs no job, so the operation cannot continue past its next
/// nonisolated step. Thus a test can put a chosen event between the moment an
/// answer arrives and the moment the caller reads it, with no fixed sleep.
///
/// The queue is the executor itself and holds no state of its own, so it is
/// not shared mutable state. A suspended Dispatch queue must resume before it
/// is released, so ``whileHeld(isolation:_:)`` is the only way to hold the executor.
final class HoldableTaskExecutor: TaskExecutor {
    /// The serial queue that runs each job of the executor.
    private let queue = DispatchQueue(label: "HoldableTaskExecutor")

    /// Puts one job on the queue of the executor.
    ///
    /// - Parameter job: The job to run.
    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }

    /// Holds each job of the executor while `body` runs, and then lets the
    /// held jobs run in order.
    ///
    /// The executor lets the jobs through also when `body` throws.
    ///
    /// - Parameters:
    ///   - isolation: The actor that `body` runs on, which is the actor of
    ///     the caller.
    ///   - body: The work to do while the executor holds its jobs.
    /// - Returns: Whatever `body` returned.
    /// - Throws: Whatever `body` threw.
    func whileHeld<Result>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Result
    ) async rethrows -> Result {
        queue.suspend()
        defer { queue.resume() }
        return try await body()
    }
}
