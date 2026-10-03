import FoundationModelsACP

/// The `Client` that a ``ConnectionModel`` serves.
///
/// This router is a stub. It answers each permission request with the
/// `cancelled` outcome and each elicitation with the `cancel` action, which
/// are the answers of the spec for a request that nobody decided, so the
/// agent never waits for ever. It ignores each notification: each
/// ``SessionModel`` reads its updates from its own subscription. The routing
/// of the requests to the open session models replaces this stub.
struct ModelClient: Client {
    /// Ignores the update. The session model reads it from its subscription.
    ///
    /// - Parameter notification: The session-update notification.
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    /// Answers the permission request with the `cancelled` outcome.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The `cancelled` outcome.
    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        PendingPermissionRequest.cancelledResponse
    }

    /// Answers the elicitation with the `cancel` action.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: The `cancel` action.
    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        ElicitationResponseWire.cancelResponse
    }

    /// Ignores the notice. No elicitation of this router waits for it.
    ///
    /// - Parameter notification: The completion notification.
    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}
