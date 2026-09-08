import Darwin
import Dispatch
import Testing

@testable import AcpClientCore

// These tests cover `InterruptHandler`, the `Ctrl-C` half of `cli-plan.md` §11:
// the first interrupt cancels the turn, the second ends the run at once.
//
// The counting tests drive ``InterruptHandler/deliver(times:)`` rather than a
// real `SIGINT`. Two reasons, and both are about the test process rather than
// about convenience. A signal disposition is PROCESS-WIDE, so a suite that
// installed one would take `Ctrl-C` away from the test runner it happens to be
// hosted in; and a real `SIGINT` is COALESCED by `DispatchSourceSignal`, so a
// fast double press reaches one event carrying a count of two and a test that
// sent two signals could never say which shape it measured. `deliver(times:)`
// is the one entry the source's event handler calls, so driving it drives
// everything the counting decides.
//
// The disposition tests, in `InterruptDispositionTests`, DO install a
// disposition, because the claim they measure is about the disposition itself:
// ``InterruptHandler`` says it leaves no global state behind, and only the
// process-wide `SIGINT` disposition can answer whether it does. Each of those
// rows pins the starting disposition, runs, and hands the host its own back,
// so the runner keeps its `Ctrl-C` outside the microseconds a row is armed.
//
// What a real signal buys — that the run ends with the exit code §9 gives it,
// and that no agent outlives it — is the integration suite's `InterruptTests`,
// which sends `SIGINT` to a real `acp-client` process.

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

/// The signal `Ctrl-C` sends, which the handler arms itself against.
private let interruptSignalNumber = SIGINT

/// The pointer value `SIG_DFL` carries, which Swift imports as `nil`.
private let defaultDispositionPointer = 0

/// How many workers the interleaving row arms and disarms at one time.
///
/// The split this row measures is a race between two workers that both want a
/// second lock after one of them has released the first, so the row needs more
/// than one runnable worker and gains little from a great many. Eight keeps
/// every core of an ordinary machine busy and keeps the waiting queue short
/// enough that the losing side is still scheduled promptly.
private let interleavedWorkerCount = 8

/// How many arm-and-disarm rounds each worker of the interleaving row runs.
private let interleavedRoundsPerWorker = 5000

/// The pointer value of one signal disposition, so two can be compared.
///
/// `sig_t` is a C function pointer, and Swift makes no function type
/// `Equatable`. `SIG_DFL` reaches Swift as `nil`, which is the zero pointer the
/// C header spells it as.
///
/// - Parameter disposition: The disposition to read, or `nil` for `SIG_DFL`.
/// - Returns: The pointer value, which is comparable.
private func pointerValue(of disposition: sig_t?) -> Int {
    disposition.map { unsafeBitCast($0, to: Int.self) } ?? defaultDispositionPointer
}

/// The `SIGINT` disposition that stands right now.
///
/// `signal` cannot answer this on its own, because it installs whatever it is
/// given and so would change the thing it was asked to read. `sigaction` with
/// no new action reads and installs nothing.
///
/// - Returns: The pointer value of the standing disposition.
private func standingInterruptDisposition() -> Int {
    var standing = sigaction()
    sigaction(interruptSignalNumber, nil, &standing)
    return pointerValue(of: standing.__sigaction_u.__sa_handler)
}

/// Runs `body` with `SIGINT` at `SIG_DFL`, and hands the host its own
/// disposition back afterwards.
///
/// A real `acp-client` starts with `SIGINT` at `SIG_DFL`, and that is the case
/// the restore has to hold for. It is also the case a test cannot assume: a
/// runner is free to have installed a handler of its own, and a row that
/// measured whatever it happened to find would measure a different claim on
/// every host. So the starting disposition is pinned rather than read.
///
/// The work may await, because the row that sends a real signal waits for the
/// callback it owes, and the disposition has to stand for the whole of that
/// wait.
///
/// - Parameter body: The work to run while `SIGINT` stands at `SIG_DFL`.
private func withDefaultInterruptDisposition(_ body: () async -> Void) async {
    let host = signal(interruptSignalNumber, SIG_DFL)
    defer { signal(interruptSignalNumber, host) }
    await body()
}

/// What ``InterruptHandler`` does to the process-wide `SIGINT` disposition.
///
/// ``InterruptHandler`` says it leaves no global state behind, and the
/// disposition is the whole of that global state. These rows install it, so
/// they are serialized against each other: two rows arming at one time would
/// each measure the other's disposition rather than their own.
@Suite("acp-client interrupt disposition", .serialized)
struct InterruptDispositionTests {
    /// Arming has to replace the disposition, or the source watches beside a
    /// default that ends the process and the first press kills the run with
    /// the answer bytes unflushed and the agent unreaped.
    @Test("start installs SIG_IGN over the disposition that stood")
    func startInstallsIgnoreOverTheDispositionThatStood() async {
        let record = ThreadSafeBuffer<InterruptCallback>()
        let interrupts = handler(recordingInto: record)

        await withDefaultInterruptDisposition {
            interrupts.start()
            defer { interrupts.stop() }

            #expect(standingInterruptDisposition() == pointerValue(of: SIG_IGN))
        }
    }

    /// ``InterruptHandler`` leaves no global state behind, so the disposition
    /// that stood before ``InterruptHandler/start()`` stands again after
    /// ``InterruptHandler/stop()``.
    ///
    /// `SIG_DFL` is the disposition every real run arms over, and Swift
    /// imports it as `nil`. A handler that read a saved `nil` as "nothing was
    /// saved" would restore NOTHING on exactly that path, and `SIGINT` would
    /// stay ignored for the life of the process.
    @Test("stop puts back the SIG_DFL that stood before start")
    func stopPutsBackTheDefaultDispositionThatStoodBeforeStart() async {
        let record = ThreadSafeBuffer<InterruptCallback>()
        let interrupts = handler(recordingInto: record)

        await withDefaultInterruptDisposition {
            interrupts.start()
            interrupts.stop()

            #expect(standingInterruptDisposition() == pointerValue(of: SIG_DFL))
        }
    }

    /// The armed source and the disposition it displaced carry one invariant
    /// between them — an armed handler owes the process a restore — so they
    /// have to move together under one lock.
    ///
    /// Two locks let a ``InterruptHandler/stop()`` and a
    /// ``InterruptHandler/start()`` interleave between them: `stop()` clears
    /// the source and releases, `start()` then saves the `SIG_IGN` that is
    /// still standing, and the restore that follows installs `SIG_IGN` for the
    /// life of the process. That leak is STICKY — every later arming reads
    /// `SIG_IGN` back as the disposition to save — so one hit anywhere in the
    /// hammering below stands at the end of it.
    @Test("arming and disarming from many workers still puts the disposition back")
    func armingAndDisarmingFromManyWorkersStillPutsTheDispositionBack() async {
        let record = ThreadSafeBuffer<InterruptCallback>()
        let interrupts = handler(recordingInto: record)

        await withDefaultInterruptDisposition {
            DispatchQueue.concurrentPerform(iterations: interleavedWorkerCount) { _ in
                for _ in 0..<interleavedRoundsPerWorker {
                    interrupts.start()
                    interrupts.stop()
                }
            }
            interrupts.stop()

            #expect(standingInterruptDisposition() == pointerValue(of: SIG_DFL))
        }
    }

    /// A real `SIGINT` reaches the first callback while the handler is armed.
    ///
    /// The counting rows drive ``InterruptHandler/deliver(times:)`` by hand,
    /// so none of them proves that a signal the kernel delivers gets there at
    /// all. This row sends one to the test process itself: the disposition is
    /// `SIG_IGN`, so the process survives the press, and the armed source is
    /// the only thing that can move the record. The wait is bounded by
    /// `eventually`, so a handler that never delivers fails here rather than
    /// hanging.
    @Test("a real SIGINT reaches the first callback while the handler is armed")
    func aRealInterruptReachesTheFirstCallbackWhileArmed() async {
        let record = ThreadSafeBuffer<InterruptCallback>()
        let interrupts = handler(recordingInto: record)

        await withDefaultInterruptDisposition {
            interrupts.start()
            defer { interrupts.stop() }
            kill(getpid(), interruptSignalNumber)

            #expect(
                await eventually { record.elements == [.first] },
                "the press never reached the callback; the record holds \(record.elements)"
            )
        }
    }
}
