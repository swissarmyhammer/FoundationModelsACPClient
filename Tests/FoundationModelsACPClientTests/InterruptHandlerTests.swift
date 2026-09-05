import Testing

@testable import AcpClientCore

// These tests cover `InterruptHandler`, the `Ctrl-C` half of `cli-plan.md` §11:
// the first interrupt cancels the turn, the second ends the run at once.
//
// Every test here drives ``InterruptHandler/deliver(times:)`` rather than a
// real `SIGINT`. Two reasons, and both are about the test process rather than
// about convenience. A signal disposition is PROCESS-WIDE, so a suite that
// installed one would take `Ctrl-C` away from the test runner it happens to be
// hosted in; and a real `SIGINT` is COALESCED by `DispatchSourceSignal`, so a
// fast double press reaches one event carrying a count of two and a test that
// sent two signals could never say which shape it measured. `deliver(times:)`
// is the one entry the source's event handler calls, so driving it drives
// everything the counting decides.
//
// What a real signal buys — that the disposition is installed, that the source
// is armed, and that the run ends with the exit code §9 gives it — is the
// integration suite's `InterruptTests`, which sends `SIGINT` to a real
// `acp-client` process.

/// What one press of `Ctrl-C` stands for, as the handler counts them.
///
/// A real dispatch event carries the number of signals it coalesced, and every
/// test here delivers exactly one at a time.
private let onePress = 1

/// The two callbacks of one handler, recorded in the order they ran.
private enum InterruptCallback: String, Sendable {
    /// The first-interrupt callback ran.
    case first

    /// The second-interrupt callback ran.
    case second
}

/// One handler over a shared record of what its callbacks did.
///
/// - Parameter record: Receives one entry for each callback that ran.
/// - Returns: The handler, which has installed nothing.
private func handler(
    recordingInto record: ThreadSafeBuffer<InterruptCallback>
) -> InterruptHandler {
    InterruptHandler(
        onFirstInterrupt: { record.append(.first) },
        onSecondInterrupt: { record.append(.second) }
    )
}

@Suite("acp-client interrupt handler")
struct InterruptHandlerTests {
    /// A handler that has been built and never signalled has done nothing.
    /// §11 leaves a run with no interrupt exactly as it was.
    @Test("a handler that was never signalled runs neither callback")
    func aHandlerThatWasNeverSignalledRunsNeitherCallback() {
        let record = ThreadSafeBuffer<InterruptCallback>()

        _ = handler(recordingInto: record)

        #expect(record.elements.isEmpty)
    }

    /// The first interrupt runs the first callback and nothing else. §11 sends
    /// `session/cancel` there and keeps waiting, so the second callback running
    /// too would end the run one press early.
    @Test("the first delivery runs the first callback alone")
    func theFirstDeliveryRunsTheFirstCallbackAlone() {
        let record = ThreadSafeBuffer<InterruptCallback>()
        let interrupts = handler(recordingInto: record)

        interrupts.deliver(times: onePress)

        #expect(record.elements == [.first])
    }

    /// The second interrupt runs the second callback, and it does not run the
    /// first one again. §11 gives the second press the end of the run.
    @Test("the second delivery runs the second callback")
    func theSecondDeliveryRunsTheSecondCallback() {
        let record = ThreadSafeBuffer<InterruptCallback>()
        let interrupts = handler(recordingInto: record)

        interrupts.deliver(times: onePress)
        interrupts.deliver(times: onePress)

        #expect(record.elements == [.first, .second])
    }

    /// §11 names two presses and no more, so a third and every later one
    /// changes nothing. A handler that ran the second callback again would send
    /// a second `AcpClientInterrupted` into a run that is already ending.
    @Test("a third delivery and every later one run nothing")
    func aThirdDeliveryAndEveryLaterOneRunNothing() {
        let record = ThreadSafeBuffer<InterruptCallback>()
        let interrupts = handler(recordingInto: record)

        for _ in 0..<5 {
            interrupts.deliver(times: onePress)
        }

        #expect(record.elements == [.first, .second])
    }

    /// A fast double press can reach the handler from two threads at one time,
    /// and the two paths still have to be exact: each callback runs one time,
    /// and the first runs before the second. A counter read outside the lock
    /// lets both deliveries see zero and run the first callback twice.
    @Test("a concurrent double delivery still runs each callback once, in order")
    func aConcurrentDoubleDeliveryStillRunsEachCallbackOnceInOrder() async {
        let record = ThreadSafeBuffer<InterruptCallback>()
        let interrupts = handler(recordingInto: record)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask { interrupts.deliver(times: onePress) }
            }
        }

        #expect(record.elements == [.first, .second])
    }
}
