import Foundation

/// One request from the agent that waits for the user's answer: a permission
/// request or an elicitation.
///
/// ``SessionModel/pendingRequests`` and ``ConnectionModel/pendingRequests``
/// give the pending requests of both kinds in one list, in arrival order, so
/// a UI can show them as one queue. The id is the id of the item, so a
/// request keeps its identity in this list and in its typed list
/// (``SessionModel/pendingPermissions`` or
/// ``SessionModel/pendingElicitations``).
public enum PendingRequest: Identifiable, Hashable, Sendable {
    /// A permission request.
    case permission(PendingPermissionRequest)

    /// An elicitation.
    case elicitation(PendingElicitation)

    /// The id of the item.
    public var id: UUID {
        switch self {
        case .permission(let permission): permission.id
        case .elicitation(let elicitation): elicitation.id
        }
    }

    /// Merges the pending items of more than one queue into one list, in
    /// arrival order.
    ///
    /// - Parameter parts: The items of each queue, each with its arrival
    ///   number.
    /// - Returns: The requests, oldest first.
    static func inArrivalOrder(_ parts: [[(arrival: UInt64, request: PendingRequest)]]) -> [PendingRequest] {
        parts.joined().sorted { $0.arrival < $1.arrival }.map(\.request)
    }
}

/// Gives each pending item a number in arrival order, across all the queues
/// of the process.
///
/// Each ``PendingRequestQueue`` takes one number when the call of an item
/// suspends. The numbers of two queues are thus comparable, so a model can
/// merge its queues in arrival order.
@MainActor
enum PendingArrivalCounter {
    /// The number that the next arrival takes.
    private static var nextNumber: UInt64 = 0

    /// Takes the next arrival number.
    ///
    /// - Returns: A number that is larger than each number before it.
    static func next() -> UInt64 {
        defer { nextNumber += 1 }
        return nextNumber
    }
}
