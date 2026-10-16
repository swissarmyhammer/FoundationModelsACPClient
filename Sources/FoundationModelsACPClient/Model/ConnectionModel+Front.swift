import Foundation

// The front of the pending requests of the connection: the request that a UI
// shows first. It has the behavior of the front of a session model: the front
// is the oldest pending request, unless the user brought another request to
// the front. The front is a pointer into `pendingRequests`, so the order of
// that list does not change, and a new request goes at the back.

extension ConnectionModel {
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

    /// Clears ``frontRequestID`` when it names a request that left the
    /// pending list.
    ///
    /// The queue of the request-scoped elicitations calls it for each item
    /// that it removes.
    ///
    /// - Parameter id: The id of the removed request.
    func clearFrontRequest(ifItIs id: UUID) {
        if frontRequestID == id {
            frontRequestID = nil
        }
    }
}
