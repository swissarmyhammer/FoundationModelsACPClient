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
    ///   position. The queues must share one ``PendingArrivalSpace``.
    /// - Returns: The requests, oldest first.
    static func inArrivalOrder(_ parts: [[(arrival: PendingArrival, request: PendingRequest)]]) -> [PendingRequest] {
        parts.joined().sorted { $0.arrival < $1.arrival }.map(\.request)
    }
}

/// The position of one pending item in arrival order.
///
/// Two positions compare first by ``wireRank`` and then by ``localRank``. A
/// request of the agent with a wire arrival number has the wire rank of that
/// number and the local rank 0. An item with no wire number, for example a
/// call with no connection, goes after each wire request that came before it
/// and before each wire request with a larger number: it has the largest wire
/// rank that its space gave until then, and a local rank larger than 0.
struct PendingArrival: Comparable, Sendable {
    /// The wire arrival number plus 1, or, for an item with no wire number,
    /// the largest wire rank of its space when it arrived (0 before the first
    /// wire request).
    let wireRank: UInt64

    /// 0 for a wire request, or the order of an item with no wire number
    /// among the items with the same wire rank, from 1.
    let localRank: UInt64

    static func < (lhs: PendingArrival, rhs: PendingArrival) -> Bool {
        (lhs.wireRank, lhs.localRank) < (rhs.wireRank, rhs.localRank)
    }
}

/// Gives the arrival positions of the pending items of one model, in one
/// number space.
///
/// The wire arrival numbers come from one connection, and they start at 0
/// for each connection. Thus all the queues of one model share one space,
/// and the space gives a position also to an item with no wire number. Two
/// positions of one space are comparable; two positions of two spaces are
/// not.
@MainActor
final class PendingArrivalSpace {
    /// The largest wire rank that this space gave.
    private var largestWireRank: UInt64 = 0

    /// The local rank of the next item with no wire number.
    private var nextLocalRank: UInt64 = 1

    /// Makes an empty space.
    init() {}

    /// Gives the position of an item that arrives now.
    ///
    /// - Parameter wireNumber: The wire arrival number of the request, for
    ///   example `ClientSideConnection.currentRequestArrival`, or `nil` when
    ///   the item has none.
    /// - Returns: The position of the item.
    func arrival(wireNumber: UInt64?) -> PendingArrival {
        guard let wireNumber else {
            defer { nextLocalRank += 1 }
            return PendingArrival(wireRank: largestWireRank, localRank: nextLocalRank)
        }
        let wireRank = wireNumber == .max ? wireNumber : wireNumber + 1
        if wireRank > largestWireRank {
            largestWireRank = wireRank
            nextLocalRank = 1
        }
        return PendingArrival(wireRank: wireRank, localRank: 0)
    }

    /// Starts the space again, for the wire numbers of a new connection.
    ///
    /// Call it only when no queue of the space holds an item: a position
    /// from before the reset is not comparable with a position from after
    /// it.
    func reset() {
        largestWireRank = 0
        nextLocalRank = 1
    }
}
