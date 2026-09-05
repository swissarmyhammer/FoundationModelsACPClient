import Darwin
import Dispatch
import Synchronization

// `InterruptHandler` — the `Ctrl-C` half of `cli-plan.md` §11. The first press
// cancels the turn and waits; the second ends the run at once. Both paths reap
// the agent, and both exit 4.
//
// Four decisions here are not free choices.
//
// 1. **The default disposition is set to IGNORE before the source is made.**
//    A `DispatchSourceSignal` does not replace the disposition: it watches the
//    signal beside whatever the disposition is, and the default disposition of
//    `SIGINT` ends the process. So a run that armed the source alone would
//    still die on the first press, with the answer bytes unflushed and the
//    agent unreaped. `SIG_IGN` first is what makes the source the only reader.
// 2. **The event handler delivers `source.data` times, and not once.** A
//    dispatch signal source COALESCES: two signals that land between two
//    handler calls reach ONE call carrying a count of two. A handler that
//    delivered once per call would read a fast double press as a single press,
//    and §11's second press would never arrive.
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
//    tests do, and it is the same entry the source's own event handler calls.

/// How many interrupts have arrived when the FIRST callback is owed.
private let firstInterruptCount = 1

/// How many interrupts have arrived when the SECOND callback is owed.
private let secondInterruptCount = 2

/// The signal `Ctrl-C` sends, which `cli-plan.md` §11 gives this binary.
private let interruptSignal = SIGINT

/// The smallest number of deliveries one dispatch event stands for.
///
/// `DispatchSourceSignal.data` counts the signals since the last event, and a
/// handler always owes at least the one signal that woke it.
private let smallestDeliveryCount = 1

/// The `Ctrl-C` handling of one run: the first press, and the second.
///
/// Build the handler with the two things a run does about an interrupt, run
/// ``start()`` to arm it, and run ``stop()`` on every exit path. A press that
/// arrives while the handler is armed reaches ``deliver(times:)``, which runs
/// the first callback one time and the second callback one time, in that
/// order, and does nothing at all after that.
final class InterruptHandler: Sendable {
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

    /// The armed signal source, or `nil` while this handler is not armed.
    ///
    /// It is held so that ``stop()`` can cancel it, and because a dispatch
    /// source that nothing holds is torn down and stops watching.
    private let source = Mutex<(any DispatchSourceSignal)?>(nil)

    /// The `SIGINT` disposition that stood before ``start()`` replaced it.
    ///
    /// ``stop()`` puts it back, so this type leaves no global state behind.
    private let previousDisposition = Mutex<sig_t?>(nil)

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

    /// Arms the handler: `SIGINT` stops ending the process, and every press
    /// reaches ``deliver(times:)``.
    ///
    /// Running this a second time without a ``stop()`` in between arms nothing
    /// further and changes nothing, so a caller cannot lose the disposition it
    /// owes the process.
    func start() {
        source.withLock { armed in
            guard armed == nil else { return }
            // The disposition goes first. See decision 1 at the head of this
            // file for what an armed source alone would still do.
            previousDisposition.withLock { $0 = signal(interruptSignal, SIG_IGN) }
            let created = DispatchSource.makeSignalSource(
                signal: interruptSignal,
                queue: .global()
            )
            created.setEventHandler { [self] in
                // `created` is captured strongly, so the source stays alive
                // for as long as its own handler does. `stop()` cancels the
                // source, which releases the handler and breaks that cycle.
                deliver(times: Int(created.data))
            }
            created.resume()
            armed = created
        }
    }

    /// Disarms the handler and puts the `SIGINT` disposition back.
    ///
    /// Running this on a handler that was never armed changes nothing, so
    /// every exit path can run it.
    func stop() {
        source.withLock { armed in
            armed?.cancel()
            armed = nil
        }
        previousDisposition.withLock { stored in
            guard let previous = stored else { return }
            signal(interruptSignal, previous)
            stored = nil
        }
    }

    /// Delivers `count` interrupts to the run, in order.
    ///
    /// This is the entry the armed source's event handler calls, and it is
    /// what a unit test drives in place of a real signal. The first delivery
    /// runs the first callback, the second runs the second callback, and every
    /// later delivery runs nothing: `cli-plan.md` §11 names two presses and no
    /// more.
    ///
    /// The count is a parameter because a dispatch event stands for one signal
    /// or for many. See decision 2 at the head of this file.
    ///
    /// - Parameter count: How many signals the event stood for. A count under
    ///   one still delivers one, because the event itself is a press.
    func deliver(times count: Int) {
        for _ in 0..<max(count, smallestDeliveryCount) {
            deliverOne()
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
