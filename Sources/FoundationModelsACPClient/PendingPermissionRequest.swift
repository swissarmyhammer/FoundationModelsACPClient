import Foundation
import FoundationModelsACP

/// One permission request from the agent that waits for the user's answer.
///
/// A callback cannot be rendered, so the client turns each
/// `session/request_permission` call into this observable value. The UI
/// binds to it, shows the options and the context, and resolves it
/// through ``ACPSessionState/answerPermissionRequest(_:with:)`` or
/// ``ACPSessionState/cancelPermissionRequest(_:)``.
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
}
