/// A set of ids with a fixed size limit. It drops the oldest id when a new id
/// goes over the limit, so a long-running connection holds a bounded table.
struct BoundedIDSet<ID: Hashable>: Sendable where ID: Sendable {
    /// The ids, oldest first.
    private var order: [ID] = []

    /// The ids, for the lookup.
    private var members: Set<ID> = []

    /// The most ids that the set holds.
    let limit: Int

    /// Makes an empty set.
    ///
    /// - Parameter limit: The most ids that the set holds. It must be 1 or
    ///   more.
    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// The count of the ids in the set.
    var count: Int { members.count }

    /// Tells whether the set holds an id.
    ///
    /// - Parameter id: The id.
    /// - Returns: `true` when the set holds it.
    func contains(_ id: ID) -> Bool {
        members.contains(id)
    }

    /// Adds an id. An id that is already in the set keeps its place. When the
    /// set is over its limit, the oldest id leaves.
    ///
    /// - Parameter id: The id to add.
    mutating func insert(_ id: ID) {
        guard members.insert(id).inserted else { return }
        order.append(id)
        if members.count > limit {
            members.remove(order.removeFirst())
        }
    }

    /// Removes an id.
    ///
    /// - Parameter id: The id to remove.
    /// - Returns: `true` when the set held it.
    @discardableResult
    mutating func remove(_ id: ID) -> Bool {
        guard members.remove(id) != nil else { return false }
        order.removeAll { $0 == id }
        return true
    }

    /// Removes each id.
    mutating func removeAll() {
        order.removeAll()
        members.removeAll()
    }
}
