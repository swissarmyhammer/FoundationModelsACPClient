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

    /// The suspended call of each unresolved item, keyed by the item id. The
    /// storage is not observable; the UI binds to ``items`` instead.
    @ObservationIgnored private let calls: KeyedWaiters<UUID, Response>

    /// The response for an item that the user did not decide.
    @ObservationIgnored private let cancelledResponse: Response

    /// Makes an empty queue.
    ///
    /// - Parameter cancelledResponse: The response for an item that the user
    ///   did not decide.
    init(cancelledResponse: Response) {
        self.cancelledResponse = cancelledResponse
        calls = KeyedWaiters(cancelledValue: cancelledResponse)
    }

    /// Suspends until a resolution of the item arrives.
    ///
    /// - Parameter item: The pending item. Its id names it in the resolution
    ///   calls.
    /// - Returns: The response of the resolution, or the cancelled response.
    func awaitResponse(to item: Item) async -> Response {
        let id = item.id
        return await calls.wait(
            for: id,
            onSuspend: { items.append(item) },
            onCancel: { [weak self] in self?.removeItem(id) }
        )
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
        items.firstIndex { $0.id == id }.map { items.remove(at: $0) }
    }
}
