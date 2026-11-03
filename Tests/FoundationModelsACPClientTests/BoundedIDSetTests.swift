import Testing

@testable import FoundationModelsACPClient

// The tests of the bounded set of ids that the connection model keeps for
// closed sessions and for sessions that missed events.

struct BoundedIDSetTests {
    @Test func anIdOverTheLimitDropsTheOldestId() {
        var ids = BoundedIDSet<Int>(limit: 2)

        ids.insert(1)
        ids.insert(2)
        ids.insert(3)

        #expect(!ids.contains(1))
        #expect(ids.contains(2) && ids.contains(3))
        #expect(ids.count == 2)
    }

    @Test func anIdThatIsAlreadyInTheSetKeepsItsPlace() {
        var ids = BoundedIDSet<Int>(limit: 2)
        ids.insert(1)
        ids.insert(2)

        ids.insert(1)
        ids.insert(3)

        #expect(!ids.contains(1))
        #expect(ids.contains(2) && ids.contains(3))
    }

    @Test func aRemovedIdLeavesRoomForANewId() {
        var ids = BoundedIDSet<Int>(limit: 2)
        ids.insert(1)
        ids.insert(2)

        ids.remove(1)
        ids.insert(3)

        #expect(ids.contains(2) && ids.contains(3))
    }

    @Test func anIdOverTheLimitIsReturnedAsEvicted() {
        var ids = BoundedIDSet<Int>(limit: 1)
        ids.insert(1)

        #expect(ids.insert(2) == 1)
    }

    @Test func anIdWithinTheLimitEvictsNothing() {
        var ids = BoundedIDSet<Int>(limit: 2)

        #expect(ids.insert(1) == nil)
    }
}
