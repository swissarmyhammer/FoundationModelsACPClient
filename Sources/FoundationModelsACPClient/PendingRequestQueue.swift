import Foundation

/// Holds the pending user requests of one kind, and resumes each suspended
/// call exactly one time.
///
/// The queue joins the observable list of pending items and the continuation
/// lifecycle of ``KeyedWaiters``, keyed by the id of each item, so each owner
/// — a session model, a session state, or a client — keeps no copy of that
/// lifecycle. An item appears in ``items`` when its call suspends, and it
/// leaves ``items`` when a resolution resumes the call:
///
/// - ``resolve(_:with:)`` resumes the call with the given response.
/// - ``cancel(_:)`` and ``cancelAll()`` resume the call with the cancelled
///   response.
/// - Cancellation of the task that awaits the call resumes it with the
///   cancelled response. The connection cancels that task when the agent
///   withdraws the request with `$/cancel_request`, or when the transport
///   closes. A `session/cancel` that the client sends does not cancel that
///   task: ``SessionModel/cancel(meta:)`` answers each pending item itself.
///
/// This is the concurrency policy: more than one item can be pending at the
/// same time. Each item keeps its position until it resolves, and each item
/// resolves independently of the others.
@MainActor @Observable
final class PendingRequestQueue<Item: Identifiable & Sendable, Response: Sendable> where Item.ID == UUID {
    /// The items that wait for the user's answer, in arrival order: the
    /// order of their arrival positions.
    private(set) var items: [Item] = []

    /// The suspended call of each unresolved item, keyed by the item id. The
    /// storage is not observable; the UI binds to ``items`` instead.
    @ObservationIgnored private let calls: KeyedWaiters<UUID, Response>

    /// The arrival position of each item in ``items``, keyed by the item id.
    /// ``arrivalSpace`` gives it when the call suspends.
    @ObservationIgnored private var arrivals: [UUID: PendingArrival] = [:]

    /// The number space of the arrival positions. The queues of one model
    /// share one space, so their positions are comparable.
    @ObservationIgnored let arrivalSpace: PendingArrivalSpace

    /// The id of each item that the cancel of its own task removed, until its
    /// call returns. ``awaitResponse(to:arrival:)`` reads and removes the id.
    @ObservationIgnored private var cancelledByTask: Set<UUID> = []

    /// Gets the id of each item that leaves ``items``, for each resolution
    /// and each cancellation, or `nil` to tell nobody.
    @ObservationIgnored var didRemove: (@MainActor (UUID) -> Void)?

    /// The response for an item that the user did not decide.
    @ObservationIgnored private let cancelledResponse: Response

    /// Makes an empty queue.
    ///
    /// - Parameters:
    ///   - cancelledResponse: The response for an item that the user did not
    ///     decide.
    ///   - arrivals: The arrival space of the model. Give each queue of one
    ///     model the same space.
    init(cancelledResponse: Response, arrivals: PendingArrivalSpace = PendingArrivalSpace()) {
        self.cancelledResponse = cancelledResponse
        arrivalSpace = arrivals
        calls = KeyedWaiters(cancelledValue: cancelledResponse)
    }

    /// Suspends until a resolution of the item arrives.
    ///
    /// The item goes into ``items`` before the first item with a larger
    /// arrival position. The connection handles each request of the agent in
    /// its own task, so a request can get here after a request that was later
    /// on the wire. With the wire number as `arrival`, ``items`` is still in
    /// wire order. ``arrivalSpace`` gives the position of each item in one
    /// number space, also for an item with no wire number.
    ///
    /// - Parameters:
    ///   - item: The pending item. Its id names it in the resolution calls.
    ///   - arrival: The wire arrival number of the item, for example
    ///     `ClientSideConnection.currentRequestArrival`, or `nil` when the
    ///     item has none. An item with no wire number goes after each item
    ///     that is pending when its call suspends.
    /// - Returns: The response of the resolution, or the cancelled response,
    ///   and whether the cancel of the task of the call removed the item.
    ///   That flag is `false` for each resolution of the user or of the
    ///   model, and for a task that was cancelled before the item was
    ///   pending.
    func awaitResponse(
        to item: Item,
        arrival: UInt64? = nil
    ) async -> (response: Response, cancelledByTask: Bool) {
        let id = item.id
        let response = await calls.wait(
            for: id,
            onSuspend: {
                let position = arrivalSpace.arrival(wireNumber: arrival)
                arrivals[id] = position
                let index = items.firstIndex { arrivals[$0.id].map { $0 > position } ?? false } ?? items.endIndex
                items.insert(item, at: index)
            },
            onCancel: { [weak self] in
                // The waiters run this step on the main actor at once after
                // the resume, so the flag is set before this call returns.
                if self?.removeItem(id) != nil {
                    self?.cancelledByTask.insert(id)
                }
            }
        )
        return (response, cancelledByTask.remove(id) != nil)
    }

    /// Gives each item of ``items`` as a ``PendingRequest``, with its
    /// arrival position. A read of it tracks ``items``.
    ///
    /// - Parameter wrap: Makes the request of one item.
    /// - Returns: The requests, in arrival order, each with its position.
    func requestsWithArrival(_ wrap: (Item) -> PendingRequest) -> [(arrival: PendingArrival, request: PendingRequest)] {
        items.compactMap { item in
            arrivals[item.id].map { (arrival: $0, request: wrap(item)) }
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
        guard calls.resumeFirst(of: id, with: response) else { return nil }
        return removeItem(id)
    }

    /// Cancels one item and resumes its call with the cancelled response.
    ///
    /// An unknown or already resolved id changes nothing.
    ///
    /// - Parameter id: The id of the item.
    /// - Returns: The removed item, or `nil` when no item was removed.
    @discardableResult
    func cancel(_ id: UUID) -> Item? {
        resolve(id, with: cancelledResponse)
    }

    /// Cancels every pending item.
    func cancelAll() {
        for id in items.map(\.id) {
            cancel(id)
        }
    }

    /// Removes one item from ``items``.
    ///
    /// - Parameter id: The id of the item.
    /// - Returns: The removed item, or `nil` when no item has that id.
    @discardableResult
    private func removeItem(_ id: UUID) -> Item? {
        arrivals[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        didRemove?(id)
        return removed
    }
}
