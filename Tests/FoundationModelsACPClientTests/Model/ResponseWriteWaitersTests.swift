import Foundation
import Testing

@testable import FoundationModelsACPClient

/// The tests of `ResponseWriteWaiters`: the "written" signal of an id ends the
/// wait of its caller, also when the signal arrives before the wait. A wait
/// that never ends would suspend for ever, so the suite has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ResponseWriteWaitersTests {
    @Test func aSignalBeforeTheWaitEndsTheWaitAtOnce() async {
        let waiters = ResponseWriteWaiters()
        let id = UUID()
        waiters.expect(id)

        waiters.signal(id)

        await waiters.waitUntilWritten(id)
    }
}
