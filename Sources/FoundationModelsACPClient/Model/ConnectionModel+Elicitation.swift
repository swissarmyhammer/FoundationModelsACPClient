import Foundation
import FoundationModelsACP

// The elicitation part of `ConnectionModel`: the pending request-scoped
// elicitations, the replies of the user, and the route of an
// `elicitation/complete` notification to the model that holds its
// elicitation.
//
// A request-scoped elicitation has no session, so no session model can hold
// it. The connection model is its home. The elicitation names the wire id of a
// client request, for example the `auth/login` of `login(_:)`. The model holds
// it while that request is in flight. The outgoing-request events of the
// connection tell the model when the request finishes, and the model then
// cancels each elicitation that names it, so the agent never waits for ever.
// The shared `PendingRequestQueue` holds the lifecycle, so each resolution
// resumes the agent's call exactly one time.

extension ConnectionModel {
    /// The request-scoped elicitations that wait for the user's answer, in
    /// arrival order.
    ///
    /// Each one names a client request that is in flight, and
    /// ``PendingElicitation/requestMethod`` tells which operation asked. More
    /// than one elicitation can be pending at the same time. Resolve one
    /// elicitation with ``acceptElicitation(_:content:)``,
    /// ``declineElicitation(_:)``, or ``cancelElicitation(_:)``.
    public var pendingElicitations: [PendingElicitation] {
        elicitations.items
    }

    /// Suspends until the user answers or cancels a request-scoped
    /// elicitation.
    ///
    /// The model looks up the method of the named request and adds the
    /// elicitation to ``pendingElicitations`` on the main actor, with no
    /// suspension between the two. A finish of that request therefore comes
    /// either before the lookup, which then finds no request, or after the
    /// elicitation is pending, which then cancels it. The elicitation is
    /// pending until one of these resolutions arrives:
    ///
    /// - ``acceptElicitation(_:content:)`` answers with the accept action.
    /// - ``declineElicitation(_:)`` answers with the decline action.
    /// - ``completeElicitation(elicitationId:)`` answers a url-mode
    ///   elicitation with the accept action and no content.
    /// - ``cancelElicitation(_:)``, the finish of the named request, the
    ///   close of the connection, a new connection, and cancellation of the
    ///   surrounding task answer with the cancel action.
    ///
    /// - Parameters:
    ///   - request: The request-scoped elicitation from the agent.
    ///   - requestId: The wire id of the client request that it names.
    /// - Returns: The user's response as the spec's action object, or `nil`
    ///   when no request of the open connection with that id is in flight.
    func awaitRequestScopedElicitation(
        _ request: CreateElicitationRequest,
        requestId: RequestId
    ) async -> CreateElicitationResponse? {
        guard let method = connection?.inFlightMethod(for: requestId) else { return nil }
        let pending = PendingElicitation(id: UUID(), request: request, requestMethod: method)
        return await elicitations.awaitResponse(to: pending)
    }

    /// Accepts one pending request-scoped elicitation.
    ///
    /// For a form-mode elicitation, give the form values as `content`; the
    /// values must match the requested schema. For a url-mode elicitation,
    /// give no content: the URL flow returns its data out of band. A call with
    /// an unknown or already resolved id changes nothing.
    ///
    /// - Parameters:
    ///   - id: The id of the pending elicitation.
    ///   - content: The form values, or `nil` for no content.
    public func acceptElicitation(_ id: PendingElicitation.ID, content: JSONValue? = nil) {
        elicitations.resolve(id, with: ElicitationResponseWire.acceptResponse(content: content))
    }

    /// Declines one pending request-scoped elicitation, which tells the agent
    /// that the user refused the request. A call with an unknown or already
    /// resolved id changes nothing.
    ///
    /// - Parameter id: The id of the pending elicitation.
    public func declineElicitation(_ id: PendingElicitation.ID) {
        elicitations.resolve(id, with: ElicitationResponseWire.declineResponse)
    }

    /// Cancels one pending request-scoped elicitation, with the spec's action
    /// for an elicitation that the user did not decide. A call with an
    /// unknown or already resolved id changes nothing.
    ///
    /// - Parameter id: The id of the pending elicitation.
    public func cancelElicitation(_ id: PendingElicitation.ID) {
        elicitations.cancel(id)
    }

    /// Closes the pending url-mode elicitation that an `elicitation/complete`
    /// notification names.
    ///
    /// The first open session model that holds an elicitation with that id
    /// closes it. When no open session model holds it, the request-scoped
    /// elicitation with that id closes, if one is pending.
    ///
    /// - Parameter elicitationId: The elicitation id that the notification
    ///   names.
    func completeElicitation(elicitationId: ElicitationId) {
        // The `where` clause closes the elicitation when the session holds it.
        for session in openSessions.values where session.completeElicitation(elicitationId: elicitationId) {
            return
        }
        elicitations.complete(elicitationId: elicitationId)
    }

    /// Starts the task that reads the outgoing-request events of a
    /// connection, and cancels each pending elicitation whose request
    /// finished.
    ///
    /// The subscription is made before this method returns, so the task sees
    /// each request of the connection. The task ends when the connection
    /// closes, which finishes the event stream, or when the model cancels it.
    ///
    /// - Parameter connection: The connection whose requests to watch.
    /// - Returns: The task that reads the events.
    func watchOutgoingRequests(of connection: ClientSideConnection) -> Task<Void, Never> {
        let events = connection.subscribeToOutgoingRequests()
        return Task { [weak self] in
            for await case .finished(let requestId) in events {
                self?.requestDidFinish(requestId)
            }
        }
    }

    /// Cancels each pending elicitation that names a request that finished.
    ///
    /// - Parameter requestId: The wire id of the request that finished.
    private func requestDidFinish(_ requestId: RequestId) {
        for pending in elicitations.items where pending.requestId == requestId {
            elicitations.cancel(pending.id)
        }
    }
}
