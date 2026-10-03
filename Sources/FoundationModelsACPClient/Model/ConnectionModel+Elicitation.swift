import FoundationModelsACP

// The elicitation part of `ConnectionModel`: the hook for request-scoped
// elicitations, and the route of an `elicitation/complete` notification to the
// model that holds its elicitation.
//
// A request-scoped elicitation has no session, so no session model can hold
// it. The connection model is its home. Until the connection model holds
// request-scoped elicitations as pending state, the hook answers each one with
// the cancel action, which is the spec's action for an elicitation that nobody
// decided, so the agent never waits for ever.

extension ConnectionModel {
    /// Answers a request-scoped elicitation.
    ///
    /// The connection model does not hold request-scoped elicitations yet, so
    /// this hook answers each one with the cancel action at once.
    ///
    /// - Parameter request: The request-scoped elicitation from the agent.
    /// - Returns: The cancel action.
    func awaitRequestScopedElicitation(_ request: CreateElicitationRequest) async -> CreateElicitationResponse {
        ElicitationResponseWire.cancelResponse
    }

    /// Closes the pending url-mode elicitation that an `elicitation/complete`
    /// notification names.
    ///
    /// The first open session model that holds an elicitation with that id
    /// closes it. When no open session model holds it, the request-scope hook
    /// gets the id.
    ///
    /// - Parameter elicitationId: The elicitation id that the notification
    ///   names.
    func completeElicitation(elicitationId: ElicitationId) {
        // The `where` clause closes the elicitation when the session holds it.
        for session in openSessions.values where session.completeElicitation(elicitationId: elicitationId) {
            return
        }
        completeRequestScopedElicitation(elicitationId: elicitationId)
    }

    /// Closes the pending request-scoped elicitation with this id.
    ///
    /// The connection model does not hold request-scoped elicitations yet, so
    /// no elicitation can match, and this hook changes nothing.
    ///
    /// - Parameter elicitationId: The elicitation id that the notification
    ///   names.
    func completeRequestScopedElicitation(elicitationId: ElicitationId) {}
}
