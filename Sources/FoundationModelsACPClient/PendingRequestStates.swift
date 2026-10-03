import Foundation

/// Holds the continuation lifecycle of pending user requests, keyed by a
/// local request id.
///
/// A pending user request — a permission request or an elicitation — moves
/// through three mutually exclusive states between arrival and resolution.
/// A resolved request has no entry at all, so no state and no continuation
/// outlives a request. ``PendingRequestQueue`` is the one user of this store,
/// so the lifecycle logic exists one time.
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

/// Holds the pending user requests of one kind, and resumes each suspended
/// call exactly one time.
///
/// The queue joins the observable list of pending items and the continuation
/// lifecycle of ``PendingRequestStates``, so each owner — a session model, a
/// session state, or a client — keeps no copy of that lifecycle. An item
/// appears in ``items`` when its call suspends, and it leaves ``items`` when a
/// resolution resumes the call:
///
/// - ``resolve(_:with:)`` resumes the call with the given response.
/// - ``cancel(_:)`` and ``cancelAll()`` resume the call with the cancelled
///   response.
/// - Cancellation of the task that awaits the call resumes it with the
///   cancelled response. The connection cancels that task when the agent
///   withdraws the request, when the turn gets cancelled, or when the
///   transport closes.
///
/// This is the concurrency policy: more than one item can be pending at the
/// same time. Each item keeps its position until it resolves, and each item
/// resolves independently of the others.
@MainActor @Observable
final class PendingRequestQueue<Item: Identifiable & Sendable, Response: Sendable> where Item.ID == UUID {
    /// The items that wait for the user's answer, in arrival order.
    private(set) var items: [Item] = []

    /// The lifecycle state of each unresolved item. The storage is not
    /// observable; the UI binds to ``items`` instead.
    @ObservationIgnored private var states = PendingRequestStates<Response>()

    /// The response for an item that the user did not decide.
    @ObservationIgnored private let cancelledResponse: Response

    /// Makes an empty queue.
    ///
    /// - Parameter cancelledResponse: The response for an item that the user
    ///   did not decide.
    init(cancelledResponse: Response) {
        self.cancelledResponse = cancelledResponse
    }

    /// Suspends until a resolution of the item arrives.
    ///
    /// - Parameter item: The pending item. Its id names it in the resolution
    ///   calls.
    /// - Returns: The response of the resolution, or the cancelled response.
    func awaitResponse(to item: Item) async -> Response {
        let id = item.id
        states.recordArrival(of: id)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard states.suspend(id, with: continuation) else {
                    continuation.resume(returning: cancelledResponse)
                    return
                }
                items.append(item)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id)
            }
        }
    }

    /// Removes one item and resumes its call with the response.
    ///
    /// An unknown or already resolved id changes nothing, so no call resumes
    /// two times.
    ///
    /// - Parameters:
    ///   - id: The id of the item.
    ///   - response: The response to resume the call with.
    /// - Returns: The removed item, or `nil` when nothing changed.
    @discardableResult
    func resolve(_ id: UUID, with response: Response) -> Item? {
        guard let continuation = states.takeSuspended(id) else { return nil }
        let removed = items.firstIndex { $0.id == id }.map { items.remove(at: $0) }
        continuation.resume(returning: response)
        return removed
    }

    /// Cancels one item and resumes its call with the cancelled response.
    ///
    /// An item whose call is not suspended yet is marked, so its call answers
    /// the cancellation when it registers. An unknown or already resolved id
    /// changes nothing.
    ///
    /// - Parameter id: The id of the item.
    /// - Returns: The removed item, or `nil` when no item was removed.
    @discardableResult
    func cancel(_ id: UUID) -> Item? {
        guard states.noteCancellation(of: id) else { return nil }
        return resolve(id, with: cancelledResponse)
    }

    /// Cancels every pending item.
    func cancelAll() {
        for id in items.map(\.id) {
            cancel(id)
        }
    }
}
