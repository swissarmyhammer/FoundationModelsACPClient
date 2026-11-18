import FoundationModelsACP

@testable import FoundationModelsACPClient

/// The helpers of the tests that close the connection after the agent
/// answered a request, but before the connection model reads the answer.
///
/// The session factory tests and the fork tests of the connection model
/// share them.
enum HeldRequest {
    /// Reads the outgoing-request events until the first request with a
    /// wire method finished.
    ///
    /// The connection sends `finished` when it takes the answer of the agent,
    /// before the caller of the request continues.
    ///
    /// - Parameters:
    ///   - method: The wire method of the request.
    ///   - events: The outgoing-request events of the connection, from a
    ///     subscription made before the request started.
    /// - Returns: `true` when the request finished, or `false` when the
    ///   stream ended first.
    static func finished(_ method: String, in events: AsyncStream<OutgoingRequestEvent>) async -> Bool {
        var requestId: RequestId?
        for await event in events {
            switch event {
            case .started(let id, method):
                requestId = id
            case .finished(let id) where id == requestId:
                return true
            case .started, .finished:
                continue
            }
        }
        return false
    }

    /// Runs one operation of the connection model under a task executor that
    /// the test holds. The test then decides when the part of the call that
    /// follows the answer of the agent runs.
    ///
    /// - Parameters:
    ///   - executor: The executor that the test holds.
    ///   - operation: The operation to run.
    /// - Returns: The task of the operation.
    @MainActor
    static func run<Output: Sendable>(
        on executor: HoldableTaskExecutor,
        _ operation: @escaping @MainActor () async throws -> Output
    ) -> Task<Output, any Error> {
        Task {
            try await withTaskExecutorPreference(executor) {
                try await operation()
            }
        }
    }
}
