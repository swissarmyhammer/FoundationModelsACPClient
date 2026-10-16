import Foundation
import FoundationModelsACP

/// One request that the agent withdrew with `$/cancel_request` while it was
/// pending, and the reason that the agent gave.
///
/// ``SessionModel/withdrawnRequests`` and ``ConnectionModel/withdrawnRequests``
/// hold these records, so a UI can tell the user why a question went away.
/// The id is the id that the request had while it was pending, so a UI can
/// match the record to the card that it showed.
public struct WithdrawnRequest: Identifiable, Hashable, Sendable {
    /// The id that the request had in `pendingRequests`.
    public let id: UUID

    /// The request as it was pending.
    public let request: PendingRequest

    /// The reason that the agent gave in the `_meta` of its
    /// `$/cancel_request`, under `CancelRequestNotification.reasonMetaKey`, or
    /// `nil` when the agent gave no reason or a value that is not a string.
    public let reason: String?

    /// Makes the record of one withdrawn request.
    ///
    /// - Parameters:
    ///   - request: The request as it was pending.
    ///   - cancelMeta: The `_meta` of the `$/cancel_request`, or `nil`.
    init(request: PendingRequest, cancelMeta: JSONValue?) {
        self.id = request.id
        self.request = request
        self.reason = Self.reason(in: cancelMeta)
    }

    /// Gives the reason in the `_meta` of a `$/cancel_request`.
    ///
    /// - Parameter meta: The `_meta` of the notification, or `nil`.
    /// - Returns: The reason, or `nil` when there is no string under
    ///   `CancelRequestNotification.reasonMetaKey`.
    static func reason(in meta: JSONValue?) -> String? {
        guard case .object(let members) = meta,
            case .string(let reason)? = members[CancelRequestNotification.reasonMetaKey]
        else { return nil }
        return reason
    }

    /// Tells whether the agent's `$/cancel_request` cancelled the inbound
    /// request that the calling task handles.
    ///
    /// The transport close also cancels each handler task, before the model
    /// learns of the close. Only this read tells the two apart.
    static var currentTaskWasWithdrawnByPeer: Bool {
        ClientSideConnection.cancelledByPeer
    }
}
