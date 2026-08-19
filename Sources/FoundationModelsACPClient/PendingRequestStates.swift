import Foundation

/// Holds the continuation lifecycle of pending user requests, keyed by a
/// local request id.
///
/// A pending user request — a permission request or an elicitation — moves
/// through three mutually exclusive states between arrival and resolution.
/// A resolved request has no entry at all, so no state and no continuation
/// outlives a request. Both request containers use this one store, so the
/// lifecycle logic exists one time.
struct PendingRequestStates<Response> {
    /// The lifecycle state of one request between arrival and resolution.
    private enum Lifecycle {
        /// The request arrived. Its continuation is not registered yet.
        case awaitingRegistration

        /// A cancellation arrived before the continuation registered. The
        /// registration reads this case and reports it, so the
        /// continuation never suspends.
        case cancelledBeforeRegistration

        /// The agent's call is suspended on this continuation.
        case suspended(CheckedContinuation<Response, Never>)
    }

    /// The lifecycle state of each unresolved request, keyed by the
    /// request id.
    private var states: [UUID: Lifecycle] = [:]

    /// Records the arrival of one request.
    ///
    /// - Parameter id: The local id of the request.
    mutating func recordArrival(of id: UUID) {
        states[id] = .awaitingRegistration
    }

    /// Registers the continuation of one request.
    ///
    /// When a cancellation arrived before this registration, the entry is
    /// removed and the answer is `false`. The caller must then resume the
    /// continuation with its cancelled outcome at once, so the
    /// continuation never suspends.
    ///
    /// - Parameters:
    ///   - id: The local id of the request.
    ///   - continuation: The continuation the agent's call suspends on.
    /// - Returns: `true` when the continuation is registered, `false`
    ///   when the request was cancelled before registration.
    mutating func suspend(
        _ id: UUID,
        with continuation: CheckedContinuation<Response, Never>
    ) -> Bool {
        if case .cancelledBeforeRegistration = states[id] {
            states[id] = nil
            return false
        }
        states[id] = .suspended(continuation)
        return true
    }

    /// Removes and returns the suspended continuation of one request.
    ///
    /// A request whose continuation is not suspended stays unchanged and
    /// the answer is `nil`, so no continuation can resume two times.
    ///
    /// - Parameter id: The local id of the request.
    /// - Returns: The continuation, or `nil`.
    mutating func takeSuspended(_ id: UUID) -> CheckedContinuation<Response, Never>? {
        guard case .suspended(let continuation) = states[id] else { return nil }
        states[id] = nil
        return continuation
    }

    /// Records a cancellation of one request.
    ///
    /// A suspended request stays suspended and the answer is `true`. The
    /// caller must then resolve the request with its cancelled outcome. A
    /// request that awaits registration is marked, so the registration
    /// answers the cancellation itself. A call with an unknown or already
    /// resolved id changes nothing.
    ///
    /// - Parameter id: The local id of the request.
    /// - Returns: `true` when the caller must resolve the suspended
    ///   request with its cancelled outcome.
    mutating func noteCancellation(of id: UUID) -> Bool {
        switch states[id] {
        case .suspended:
            return true
        case .awaitingRegistration:
            states[id] = .cancelledBeforeRegistration
            return false
        case .cancelledBeforeRegistration, nil:
            // The request is already cancelled or already resolved.
            return false
        }
    }
}
