import Foundation
import FoundationModelsACP

/// One permission request from the agent that waits for the user's answer.
///
/// A callback cannot be rendered, so the client turns each
/// `session/request_permission` call into this observable value. The UI
/// binds to it, shows the options and the context, and resolves it
/// through ``SessionModel/selectPermission(_:option:)`` or
/// ``SessionModel/cancelPermission(_:)``.
///
/// The wire request carries no identity of its own, so the client gives
/// each pending request a local, stable identity. SwiftUI `ForEach` uses
/// that identity, and the answer and cancel calls use it to name one
/// request.
public struct PendingPermissionRequest: Identifiable, Hashable, Sendable {
    /// The local identity of the pending request.
    public let id: UUID

    /// The request as the agent sent it. It carries the options, the
    /// title, the description, and the subject context, so the UI can
    /// show what the agent asks permission for.
    public let request: RequestPermissionRequest

    /// The response for a request that the user did not decide: the
    /// `cancelled` outcome. It never selects an option for the user.
    static let cancelledResponse = RequestPermissionResponse(outcome: .cancelled)

    /// Makes the response for a request that the user answered.
    ///
    /// - Parameter optionId: The id of the option that the user selected.
    /// - Returns: The response with the `selected` outcome.
    static func selectedResponse(_ optionId: PermissionOptionId) -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .selected(SelectedPermissionOutcome(optionId: optionId)))
    }
}
