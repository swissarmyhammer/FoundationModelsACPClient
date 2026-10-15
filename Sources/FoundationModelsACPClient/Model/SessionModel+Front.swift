import Foundation

// The front of the pending requests of a session: the request that a UI shows
// first. The front is the oldest pending request, unless the user brought
// another request to the front, for example from the "Waiting for your
// answer" status of a tool call. The front is a pointer into
// `pendingRequests`, so the order of that list does not change.

extension SessionModel {
    /// The pending request to show first.
    ///
    /// It is the request with ``frontRequestID`` when that request is still
    /// pending. Else it is the oldest request of ``pendingRequests``. It is
    /// `nil` when no request is pending.
    public var frontRequest: PendingRequest? {
        let requests = pendingRequests
        return requests.first { $0.id == frontRequestID } ?? requests.first
    }

    /// Brings one pending request to the front.
    ///
    /// The order of ``pendingRequests`` does not change. An id that is not
    /// pending changes nothing.
    ///
    /// - Parameter id: The id of the pending request.
    public func bringToFront(_ id: PendingRequest.ID) {
        guard pendingRequests.contains(where: { $0.id == id }) else { return }
        frontRequestID = id
    }

    /// Brings the oldest pending elicitation that a tool-call entry links to
    /// the front.
    ///
    /// The "Waiting for your answer" status of a tool call uses it.
    ///
    /// - Parameter entry: The tool-call entry, which links its pending
    ///   elicitations through ``ToolCallEntry/linkedElicitationIDs``.
    /// - Returns: `true` when the entry links a pending elicitation, `false`
    ///   when nothing changed.
    @discardableResult
    public func bringToFront(toolCall entry: ToolCallEntry) -> Bool {
        let linked = Set(entry.linkedElicitationIDs)
        guard let oldest = pendingElicitations.first(where: { linked.contains($0.id) }) else { return false }
        frontRequestID = oldest.id
        return true
    }

    /// Clears ``frontRequestID`` when it names a request that left the
    /// pending lists.
    ///
    /// Each pending queue calls it for each item that it removes, so the
    /// pointer becomes `nil` at each resolution of the front request,
    /// including the close of the session.
    ///
    /// - Parameter id: The id of the removed request.
    func clearFrontRequest(ifItIs id: UUID) {
        if frontRequestID == id {
            frontRequestID = nil
        }
    }
}
