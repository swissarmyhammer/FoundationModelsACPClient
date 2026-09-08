import Darwin
import Dispatch
import Synchronization

// `InterruptHandler` — the `Ctrl-C` half of `cli-plan.md` §11. The first press
// cancels the turn and waits; the second ends the run at once. Both paths reap
// the agent, and both exit 4.
//
// Seven decisions here are not free choices.
//
// 1. **The default disposition is set to IGNORE before the source is made.**
//    A `DispatchSourceSignal` does not replace the disposition: it watches the
//    signal beside whatever the disposition is, and the default disposition of
//    `SIGINT` ends the process. So a run that armed the source alone would
//    still die on the first press, with the answer bytes unflushed and the
//    agent unreaped. `SIG_IGN` first is what makes the source the only reader.
// 2. **The event handler stores `source.data`, and not one.** A dispatch
//    signal source COALESCES: two signals that land between two handler calls
//    reach ONE call carrying a count of two. A handler that recorded one press
//    per call would read a fast double press as a single press, and §11's
//    second press would never arrive. So the flag is a count, never a `Bool`.
// 3. **The counter is read and advanced UNDER the lock, and the callback runs
//    there too.** The two paths have to be exact — each callback one time, the
//    first before the second — and a counter read outside the lock lets two
//    threads both see zero and both cancel. The callbacks a caller gives are
//    yields into a buffering `AsyncStream`, which neither blocks nor calls
//    back into this type, so holding the lock across them costs nothing.
// 4. **`init` installs nothing.** Installing is ``start()``, and removing is
//    ``stop()``. A signal disposition is process-wide, so a unit test that
//    built a handler which installed on its own would take `Ctrl-C` away from
//    whatever process is hosting it. Driving ``deliver(times:)`` is what the
//    tests do, and it is the same entry the drain task calls.
// 5. **The armed source, the disposition it displaced and the drain task are
//    ONE value under ONE lock.** They carry a single invariant between them —
//    an armed handler owes the process a restore and owes its task a cancel —
//    and two locks let a ``stop()`` and a ``start()`` interleave between them:
//    `stop()` clears the source and releases, `start()` then saves the
//    `SIG_IGN` that is still standing, and the restore that follows installs
//    `SIG_IGN` for the life of the process. ``ArmedInterrupts`` under one
//    `Mutex` makes that split unwritable rather than merely absent.
// 6. **`SIG_DFL` reaches Swift as `nil`, so `nil` cannot also mean "nothing
//    was saved".** A binary starts with `SIGINT` at `SIG_DFL`, so `signal`
//    answers `nil` at the arming of every ordinary run. A saved disposition of
//    `nil` that stood for an absence would restore NOTHING on exactly that
//    path, and `SIGINT` would stay ignored for the life of the process.
//    Whether a restore is owed is answered by whether ``ArmedInterrupts``
//    stands at all, and the disposition it carries is restored whatever its
//    value is.
// 7. **The event handler body sets the flag, and the drain task does the
//    work.** §11 asks for a handler body that only sets a flag, because a
//    signal handler must be async-signal-safe, and for the work to run on a
//    normal task. So the handler adds the event's count to
//    ``InterruptHandler/pendingInterrupts``, an atomic, and returns. A task
//    that ``start()`` begins reads the flag every ``interruptPollInterval``
//    and hands the count to ``deliver(times:)``, which is where the lock, the
//    counting and the callbacks are. `InterruptHandlerSourceTests` reads this
//    file and holds the handler body to that one statement.

/// How many interrupts have arrived when the FIRST callback is owed.
private let firstInterruptCount = 1

/// How many interrupts have arrived when the SECOND callback is owed.
private let secondInterruptCount = 2

/// The signal `Ctrl-C` sends, which `cli-plan.md` §11 gives this binary.
private let interruptSignal = SIGINT

/// The count the flag holds when no press is waiting to be delivered.
private let noPendingInterrupts: UInt = 0

/// The number of milliseconds in ``interruptPollInterval``.
private let interruptPollIntervalMilliseconds = 20

/// How long the drain task sleeps between two readings of the flag.
///
/// A press reaches the run within one interval. Twenty milliseconds is under
/// what a person can notice between the press and the cancel going out, and a
/// wake every twenty milliseconds costs a run nothing.
private let interruptPollInterval: Duration = .milliseconds(interruptPollIntervalMilliseconds)

/// Everything one armed handler owns, and owes back.
///
/// The source, the disposition it displaced and the drain task carry a single
/// invariant between them — a handler that holds this value owes the process a
/// restore and owes the task a cancel — so they are one value under one lock.
/// See decision 5 at the head of this file for what two locks let a caller
/// write.
private struct ArmedInterrupts {
    /// The resumed signal source.
    ///
    /// It is held so that ``InterruptHandler/stop()`` can cancel it, and
    /// because a dispatch source that nothing holds is torn down and stops
    /// watching.
    let source: any DispatchSourceSignal

    /// The `SIGINT` disposition that stood before this arming installed
    /// `SIG_IGN`.
    ///
    /// `nil` is `SIG_DFL`, which is how Swift imports it, and NOT an absence.
    /// See decision 6 at the head of this file.
    let displacedDisposition: sig_t?

    /// The task that reads the flag and delivers what it held.
    ///
    /// It is held so that ``InterruptHandler/stop()`` can cancel it. A task
    /// nothing cancels would keep reading a flag no press can reach any more,
    /// and it would hold the handler alive with it.
    let drain: Task<Void, Never>
}

/// The `Ctrl-C` handling of one run: the first press, and the second.
///
/// Build the handler with the two things a run does about an interrupt, run
/// ``start()`` to arm it, and run ``stop()`` on every exit path. A press that
/// arrives while the handler is armed raises the flag, the drain task carries
/// it to ``deliver(times:)``, and that runs the first callback one time and the
/// second callback one time, in that order, and does nothing at all after that.
final class InterruptHandler: Sendable {
    /// How many presses the signal source has recorded that the drain task
    /// has not delivered yet.
    ///
    /// It is the flag of decision 7 at the head of this file: the one thing
    /// the source's event handler writes. It is a count and not a `Bool`,
    /// because one dispatch event can stand for two presses (decision 2), and
    /// it is atomic because the event handler and the drain task reach it from
    /// two threads.
    private let pendingInterrupts = Atomic<UInt>(noPendingInterrupts)

    /// How many interrupts this handler has delivered so far.
    ///
    /// It is a `Mutex` and not an atomic, because the counting and the
    /// dispatch have to be one indivisible step. See decision 3 at the head of
    /// this file.
    private let delivered = Mutex(0)

    /// What the run does about the first interrupt.
    private let onFirstInterrupt: @Sendable () -> Void

    /// What the run does about the second interrupt.
    private let onSecondInterrupt: @Sendable () -> Void

    /// What this handler armed, or `nil` while it is not armed.
    ///
    /// The source, the disposition it displaced and the drain task are one
    /// value under this one lock, so that no ``start()`` can run between a
    /// ``stop()`` clearing the source and the same ``stop()`` putting the
    /// disposition back. See decision 5 at the head of this file.
    private let armed = Mutex<ArmedInterrupts?>(nil)

    /// Builds the handler. It installs nothing: run ``start()`` to arm it.
    ///
    /// - Parameters:
    ///   - onFirstInterrupt: What the run does about the first interrupt.
    ///     `cli-plan.md` §11 cancels the turn there and keeps waiting.
    ///   - onSecondInterrupt: What the run does about the second interrupt.
    ///     §11 ends the run there, at once.
    init(
        onFirstInterrupt: @escaping @Sendable () -> Void,
        onSecondInterrupt: @escaping @Sendable () -> Void
    ) {
        self.onFirstInterrupt = onFirstInterrupt
        self.onSecondInterrupt = onSecondInterrupt
    }

    /// Arms the handler: `SIGINT` stops ending the process, every press raises
    /// the flag, and the drain task carries each one to ``deliver(times:)``.
    ///
    /// Running this a second time without a ``stop()`` in between arms nothing
    /// further and changes nothing, so a caller cannot lose the disposition it
    /// owes the process.
    func start() {
        armed.withLock { state in
            guard state == nil else { return }
            // The disposition goes first. See decision 1 at the head of this
            // file for what an armed source alone would still do.
            let displaced = signal(interruptSignal, SIG_IGN)
            let created = DispatchSource.makeSignalSource(
                signal: interruptSignal,
                queue: .global()
            )
            // `created` is captured strongly by its own handler, so the source
            // stays alive for as long as that handler does. `stop()` cancels
            // the source, which releases the handler and breaks that cycle.
            // The body is the one statement decision 7 at the head of this
            // file allows it.
            created.setEventHandler {
                self.pendingInterrupts.add(created.data, ordering: .sequentiallyConsistent)
            }
            // The drain stands before the source resumes, so the first press
            // has a reader the moment it can land.
            let drain = Task { await self.drainPendingInterrupts() }
            created.resume()
            state = ArmedInterrupts(
                source: created,
                displacedDisposition: displaced,
                drain: drain
            )
        }
    }

    /// Disarms the handler and puts the `SIGINT` disposition back.
    ///
    /// Running this on a handler that was never armed changes nothing, so
    /// every exit path can run it.
    ///
    /// The cancel of the task, the cancel of the source and the restore are
    /// one step under one lock, and the disposition is put back whatever its
    /// value is. See decisions 5 and 6 at the head of this file.
    func stop() {
        armed.withLock { state in
            guard let standing = state else { return }
            standing.drain.cancel()
            standing.source.cancel()
            signal(interruptSignal, standing.displacedDisposition)
            state = nil
        }
    }

    /// Delivers `count` interrupts to the run, in order.
    ///
    /// This is the entry the drain task calls with what the flag held, and it
    /// is what a unit test drives in place of a real signal. The first delivery
    /// runs the first callback, the second runs the second callback, and every
    /// later delivery runs nothing: `cli-plan.md` §11 names two presses and no
    /// more.
    ///
    /// The count is a parameter because a dispatch event stands for one signal
    /// or for many. See decision 2 at the head of this file.
    ///
    /// - Parameter count: How many presses to deliver. A round of the drain
    ///   that found the flag at zero passes zero, and zero delivers nothing.
    func deliver(times count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            deliverOne()
        }
    }

    /// Reads the flag until the task is cancelled, and delivers what it held.
    ///
    /// This is the normal task decision 7 at the head of this file puts the
    /// work on. Each round takes the count out of ``pendingInterrupts`` and
    /// puts zero back in one step, so a press that lands during a delivery
    /// waits for the next round and is never lost.
    private func drainPendingInterrupts() async {
        while !Task.isCancelled {
            let count = pendingInterrupts.exchange(
                noPendingInterrupts,
                ordering: .sequentiallyConsistent
            )
            deliver(times: Int(count))
            try? await Task.sleep(for: interruptPollInterval)
        }
    }

    /// Advances the counter by one and runs the callback that count owes.
    ///
    /// The counting and the callback are one step under one lock. See decision
    /// 3 at the head of this file.
    private func deliverOne() {
        delivered.withLock { count in
            count += 1
            switch count {
            case firstInterruptCount:
                onFirstInterrupt()
            case secondInterruptCount:
                onSecondInterrupt()
            default:
                break
            }
        }
    }
}
