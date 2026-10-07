import Foundation
import FoundationModelsACP
import Synchronization

@testable import FoundationModelsACPClient

/// A request sender that records each request and lets the test decide when
/// and how each prompt answers.
///
/// A prompt stays suspended until the test calls ``answerPrompt(with:)`` or
/// ``failPrompt(with:)``, so a test can put an echo before or after the
/// response. ``receivedPrompts`` gives each prompt request after the sender
/// is ready for its answer.
final class FakeSessionRequestSender: SessionRequestSender {
    /// The mutable state of the fake.
    private struct State {
        /// The prompt requests, in arrival order.
        var promptRequests: [PromptRequest] = []

        /// The suspended prompt calls, in arrival order.
        var waitingPrompts: [CheckedContinuation<PromptResponse, any Error>] = []

        /// The cancel notifications, in arrival order.
        var cancelNotifications: [CancelSessionNotification] = []

        /// The error that each cancel throws after the fake records it, or
        /// `nil` to send each cancel.
        var cancelError: (any Error)?

        /// The set-config-option requests, in arrival order.
        var configOptionRequests: [SetSessionConfigOptionRequest] = []

        /// The observer that each prompt request goes to at its arrival.
        var promptObserver: @Sendable @MainActor (PromptRequest) -> Void = { _ in }
    }

    /// The state of the fake.
    private let state = Mutex(State())

    /// The continuation of ``receivedPrompts``.
    private let receivedPromptsContinuation: AsyncStream<PromptRequest>.Continuation

    /// Each prompt request, given when the call waits for its answer.
    let receivedPrompts: AsyncStream<PromptRequest>

    /// Makes a fake with no request.
    init() {
        (receivedPrompts, receivedPromptsContinuation) = AsyncStream<PromptRequest>.makeStream()
    }

    /// The prompt requests, in arrival order.
    var promptRequests: [PromptRequest] {
        state.withLock { $0.promptRequests }
    }

    /// The cancel notifications, in arrival order.
    var cancelNotifications: [CancelSessionNotification] {
        state.withLock { $0.cancelNotifications }
    }

    /// The set-config-option requests, in arrival order.
    var configOptionRequests: [SetSessionConfigOptionRequest] {
        state.withLock { $0.configOptionRequests }
    }

    /// Sets the observer that each prompt request goes to at its arrival, on
    /// the main actor, before the call waits for its answer.
    ///
    /// - Parameter observer: The observer.
    func observePrompts(_ observer: @escaping @Sendable @MainActor (PromptRequest) -> Void) {
        state.withLock { $0.promptObserver = observer }
    }

    /// Records the prompt and suspends until the test answers it.
    ///
    /// The fake sends the request as the caller made it, so `willSend` gets
    /// the request unchanged, before the observer and before the suspension.
    ///
    /// - Parameters:
    ///   - request: The prompt request.
    ///   - willSend: Gets the request before the fake records it.
    /// - Returns: The response that the test gives.
    func prompt(
        _ request: PromptRequest,
        willSend: @MainActor @Sendable (PromptRequest) -> Void
    ) async throws -> PromptResponse {
        await willSend(request)
        let observer = state.withLock { $0.promptObserver }
        await observer(request)
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.promptRequests.append(request)
                state.waitingPrompts.append(continuation)
            }
            receivedPromptsContinuation.yield(request)
        }
    }

    /// Makes each later cancel throw an error, as a send that fails after a
    /// disconnect does.
    ///
    /// - Parameter error: The error that each cancel throws.
    func failCancels(with error: any Error) {
        state.withLock { $0.cancelError = error }
    }

    /// Records the cancel notification.
    ///
    /// - Parameter notification: The cancel notification.
    /// - Throws: The error of ``failCancels(with:)``, when the test set one.
    func cancel(_ notification: CancelSessionNotification) async throws {
        let error = state.withLock { state -> (any Error)? in
            state.cancelNotifications.append(notification)
            return state.cancelError
        }
        if let error {
            throw error
        }
    }

    /// Records the set-config-option request.
    ///
    /// - Parameter request: The set-config-option request.
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
        state.withLock { $0.configOptionRequests.append(request) }
    }

    /// Answers the oldest waiting prompt with a response.
    ///
    /// - Parameter response: The response to give.
    func answerPrompt(with response: PromptResponse) {
        takeOldestWaitingPrompt().resume(returning: response)
    }

    /// Fails the oldest waiting prompt with an error.
    ///
    /// - Parameter error: The error to throw.
    func failPrompt(with error: any Error) {
        takeOldestWaitingPrompt().resume(throwing: error)
    }

    /// Removes and gives the oldest waiting prompt. A test that answers a
    /// prompt that is not there is a defect of the test.
    ///
    /// - Returns: The continuation of the oldest waiting prompt.
    private func takeOldestWaitingPrompt() -> CheckedContinuation<PromptResponse, any Error> {
        state.withLock { state in
            precondition(!state.waitingPrompts.isEmpty, "the test answered a prompt that does not wait")
            return state.waitingPrompts.removeFirst()
        }
    }
}
