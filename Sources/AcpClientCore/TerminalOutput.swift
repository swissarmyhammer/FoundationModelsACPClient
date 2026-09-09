// `TerminalOutput` — the terminal layer of `cli-plan.md` §5 and §8, and the
// one file of this target that imports Noora.
//
// §5 keeps the terminal package behind a single file, so a later swap costs
// one file. `TerminalOutputTests` pins that: it walks both source directories
// of the command-line client and fails when a second file names Noora.
//
// The rule this file exists to keep is absolute. Every byte that is not the
// answer text goes to **stderr**, and nothing is drawn when stderr is not a
// terminal. stdout carries the answer and nothing else (§8). The doctor
// report of §10 is the one thing this layer writes to a stderr that is not a
// terminal, and it writes it as the plain text of the Extras renderer, which
// draws nothing and holds no escape: the report is the output of `doctor`,
// so a pipe must receive it whole.
//
// Noora does not keep that rule on its own. Three of its defaults work
// against it, and each one needs a deliberate setting here:
//
// 1. Noora writes to stdout. `StandardPipelines()` defaults its `output` to
//    `StandardOutputPipeline`, which is `print`. The progress step sends its
//    in-place drawing and its success line there. So both pipelines are built
//    over this layer's own sink, which production points at stderr.
// 2. Noora has no free-standing spinner and no free-standing in-place line.
//    `Spinner` and `Spinning` are internal to Noora. The public surface is
//    `progressStep(message:successMessage:errorMessage:showSpinner:task:)`,
//    which hands the task a closure that rewrites the line in place. So
//    ``TerminalOutput/withSpinner(_:_:)`` is the shape of the API here, and
//    the caller reports the running tool name through the closure it is
//    given. There is no separate line-drawing entry point.
// 3. Noora's own terminal gate reads the wrong descriptor.
//    `Terminal.isInteractive()` reads `STDIN_FILENO` and `Terminal.isColored()`
//    reads stdout, while §5 and §8 gate on stderr. With a piped prompt on
//    stdin — a §7 row — Noora would call itself non-interactive on a real
//    terminal. So the `Terminal` value is built from the injected reading of
//    stderr, and never from Noora's defaults.
//
// A fourth default belongs to the same list. `Terminal.init` defaults
// `signalBehavior` to `.restoreAndExit`, which installs handlers for SIGINT,
// SIGTERM, SIGQUIT and SIGHUP that print a cursor escape to **stdout** and
// then `exit(0)`. That writes to the one descriptor §8 reserves for the
// answer, and it takes Ctrl-C away from the run, which §9 owes exit code 4.
// The `Terminal` value is built with `.none`, so this binary keeps its own
// signals.
//
// Both readings this layer needs — whether stderr is a terminal, and where a
// byte goes — are injected, because a test process cannot make its own
// standard error a terminal and must not write to the real one.
//
// One name to watch. `FoundationModelsACP` exports a `TerminalOutput` of its
// own: the ACP model of what an agent-owned terminal printed. Inside this
// target the local type wins the lookup, so a file here that wants the wire
// model must write `FoundationModelsACP.TerminalOutput` in full. The two mean
// different things and neither can take the other's place.

import Darwin
import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Noora

/// How much of a run the terminal layer writes (`cli-plan.md` §8).
enum TerminalVerbosity: Sendable {
    /// Write nothing but errors, in a terminal too.
    case quiet

    /// Write nothing until the run fails.
    case normal

    /// Write the session events, one line each.
    case verbose

    /// Resolves the verbosity from the two flags of `cli-plan.md` §6.1.
    ///
    /// `--quiet` wins over `--verbose`. A person who asked for silence asked
    /// for silence, and the two flags together are a mistake this binary
    /// answers rather than reports.
    ///
    /// - Parameters:
    ///   - quiet: Whether the command line carried `--quiet`.
    ///   - verbose: Whether the command line carried `--verbose`.
    init(quiet: Bool, verbose: Bool) {
        if quiet {
            self = .quiet
        } else if verbose {
            self = .verbose
        } else {
            self = .normal
        }
    }
}

/// Everything the binary writes that is not the answer text.
///
/// One value owns the whole of stderr: the session events of `--verbose`, the
/// error lines, the progress drawing, the doctor report, and the connection's
/// own diagnostics through ``logger``. Nothing here can reach stdout, because
/// nothing here holds a way to write to it.
struct TerminalOutput: Sendable {
    /// How much of the run this layer writes.
    let verbosity: TerminalVerbosity

    /// Whether standard error was a terminal when this value was built.
    ///
    /// The descriptor is read one time, in `init`, because Noora's `Terminal`
    /// is an immutable value built at the same moment. One reading keeps the
    /// gate on ``withSpinner(_:_:)`` and the gate inside Noora from ever
    /// disagreeing.
    private let standardErrorIsATerminal: Bool

    /// Receives every byte this layer writes, verbatim.
    ///
    /// The text arrives exactly as it goes out, terminators and escape
    /// sequences included, so a test can assert bytes. It is called from the
    /// spinner's own thread as well as from the caller's task, so it must
    /// tolerate calls from more than one thread.
    private let sink: @Sendable (String) -> Void

    /// The Noora instance, with both of its pipelines pointed at ``sink``.
    private let noora: Noora

    /// Builds the terminal layer.
    ///
    /// - Parameters:
    ///   - verbosity: How much of the run to write.
    ///   - isStandardErrorATerminal: Answers whether standard error is a
    ///     terminal. It is called once, here. The default asks the C library.
    ///   - sink: Receives every byte this layer writes, verbatim. The default
    ///     writes to this binary's own standard error.
    init(
        verbosity: TerminalVerbosity,
        isStandardErrorATerminal: @Sendable () -> Bool = { Self.standardErrorIsATerminal() },
        sink: @escaping @Sendable (String) -> Void = { Self.writeToStandardError($0) }
    ) {
        let isATerminal = isStandardErrorATerminal()
        let pipeline = SinkPipeline(sink: sink)
        self.verbosity = verbosity
        self.sink = sink
        standardErrorIsATerminal = isATerminal
        noora = Noora(
            terminal: Terminal(
                isInteractive: isATerminal,
                isColored: isATerminal,
                signalBehavior: .none
            ),
            standardPipelines: StandardPipelines(output: pipeline, error: pipeline)
        )
    }

    /// A bridge that sends the connection's diagnostics to ``event(_:)``.
    ///
    /// The wire package's own `ACPLogger.standardError` would do as well for
    /// the descriptor, but not for the verbosity: §8 gives a default run
    /// nothing on stderr until it fails. Routing through ``event(_:)`` keeps
    /// the diagnostics behind `--verbose`, and keeps them off stdout.
    var logger: ACPLogger {
        ACPLogger { self.event($0) }
    }

    /// Writes one session event, at `.verbose` and nowhere else.
    ///
    /// - Parameter line: The event text, without a terminator. This layer adds
    ///   the line ending.
    func event(_ line: String) {
        guard verbosity == .verbose else { return }
        writeLine(line)
    }

    /// Writes one teed ndJSON frame line, at every verbosity.
    ///
    /// `cli-plan.md` §6.1 makes `--frames` a debugging switch and not a
    /// verbosity level, so a person who asked for the frames gets them at
    /// `--quiet` too, and gets them whether or not standard error is a
    /// terminal. That is why this is its own member rather than a call of
    /// ``event(_:)``, which `--verbose` gates, or of ``error(_:)``, which says
    /// something went wrong.
    ///
    /// - Parameter line: The teed line, already carrying its direction mark
    ///   and no terminator. This layer adds the line ending.
    func frame(_ line: String) {
        writeLine(line)
    }

    /// Writes one error line, at every verbosity.
    ///
    /// `--quiet` writes nothing but errors (§8), so this is the one thing that
    /// silence does not cover: a run that fails without a word is a run a
    /// person cannot debug.
    ///
    /// - Parameter line: The error text, without a terminator. This layer adds
    ///   the line ending.
    func error(_ line: String) {
        writeLine(line)
    }

    /// Writes the doctor report to standard error, at every verbosity.
    ///
    /// `cli-plan.md` §8 sends the human doctor report to standard error, and
    /// §5 gives it to this layer. In a terminal the report is Noora's table,
    /// the same four columns the agent CLI of this family draws, so the two
    /// CLIs draw alike. A pipe or a file gets the plain rendering of
    /// `FoundationModelsExtras` instead: its bytes hold no escape, and two
    /// runs over the same findings write the same bytes, so a script reads a
    /// stable report. The report is the whole output of `doctor`, so `--quiet`
    /// does not silence it, which is what §6.2 means when it calls that
    /// option inert for `doctor`.
    ///
    /// Noora lays the table out against `Terminal.size()`, which reads the
    /// width of standard OUTPUT. A run whose stdout is a pipe while stderr is
    /// a terminal is laid out at Noora's fallback width, and a cell that does
    /// not fit is cut short with an ellipsis rather than wrapped.
    ///
    /// - Parameter report: The findings to draw.
    func doctorReport(_ report: DoctorReport) {
        guard standardErrorIsATerminal else {
            sink(PlainTextDoctorRenderer().render(report))
            return
        }
        noora.table(
            headers: Self.plainCells([Self.doctorStatusHeader] + Self.doctorColumnHeaders),
            rows: report.checks.map(Self.doctorRow(for:)),
            renderer: Renderer()
        )
    }

    /// The header of the status column of the drawn doctor table.
    private static let doctorStatusHeader = "Status"

    /// The headers of the doctor table after the status column, in the order
    /// the plain rendering carries the same three texts.
    private static let doctorColumnHeaders = ["Check", "Message", "Fix"]

    /// The status cell of a row whose check passed.
    private static let doctorPassedMark = "✔︎"

    /// The status cell of a row whose check needs attention.
    private static let doctorWarnedMark = "!"

    /// The status cell of a row whose check failed.
    private static let doctorFailedMark = "⨯"

    /// The fix cell of a row whose check states no fix.
    private static let doctorNoFixText = ""

    /// The drawn row of one finding: its status mark, its name, its message,
    /// and its fix.
    ///
    /// - Parameter check: The finding to draw.
    /// - Returns: One cell for the status column and one for each of
    ///   ``doctorColumnHeaders``.
    private static func doctorRow(for check: HealthCheck) -> StyledTableRow {
        [statusCell(for: check.status)]
            + plainCells([check.name, check.message, check.fix ?? doctorNoFixText])
    }

    /// The status cell of one health status, in the color of the status.
    ///
    /// The switch is total and declares no `default`: a status Extras gains
    /// later must be drawn on purpose, and the compiler is what asks for that.
    ///
    /// - Parameter status: The status the check reported.
    /// - Returns: The styled cell.
    private static func statusCell(for status: HealthStatus) -> TableCellStyle {
        switch status {
        case .ok: .success(doctorPassedMark)
        case .warning: .warning(doctorWarnedMark)
        case .error: .danger(doctorFailedMark)
        }
    }

    /// Cells that carry text and no color.
    ///
    /// - Parameter texts: The texts, in column order.
    /// - Returns: One cell for each text.
    private static func plainCells(_ texts: [String]) -> [TableCellStyle] {
        texts.map { .plain($0) }
    }

    /// Hands one line and its terminator to ``sink``.
    ///
    /// The three entry points above differ in WHEN they write, and they agree
    /// on WHAT a written line looks like. That agreement lives here, so a
    /// caller of any of the three never writes its own line ending.
    ///
    /// - Parameter line: The text to write, without a terminator.
    private func writeLine(_ line: String) {
        sink(line + "\n")
    }

    /// Runs `body` while a plain spinner turns on standard error.
    ///
    /// The spinner is drawn only when standard error is a terminal and the
    /// verbosity is not `.quiet`. A pipe, a file and `--quiet` each get zero
    /// bytes, and `body` still runs and still receives a working line closure
    /// that draws nothing.
    ///
    /// The success and the error message are both left to the label, so the
    /// closing line repeats the neutral label and never the last tool name the
    /// caller reported. §8 asks for a spinner that carries no claim about what
    /// the agent is doing, and a closing line naming a tool would be such a
    /// claim.
    ///
    /// This is `throws` and not `rethrows`, although a non-throwing body can
    /// never make it throw. Noora's `progressStep` is declared `throws`, and
    /// Swift forbids an unconditionally-throwing call inside a `rethrows`
    /// function, so `rethrows` here does not compile.
    ///
    /// - Parameters:
    ///   - label: The neutral label for the work, shown while it runs and
    ///     repeated when it ends.
    ///   - body: The work to run. Its argument rewrites the drawn line in
    ///     place, which is where the caller reports the running tool name.
    /// - Returns: Whatever `body` returned.
    /// - Throws: Whatever `body` threw.
    func withSpinner<T>(
        _ label: String,
        _ body: @escaping (@escaping @Sendable (String) -> Void) async throws -> T
    ) async throws -> T {
        guard standardErrorIsATerminal, verbosity != .quiet else {
            return try await body { _ in }
        }
        return try await noora.progressStep(
            message: label,
            successMessage: nil,
            errorMessage: nil,
            showSpinner: true,
            task: body
        )
    }

    /// Answers whether this binary's own standard error is a terminal.
    ///
    /// - Returns: `true` when file descriptor 2 is a terminal, and `false`
    ///   when it is a pipe, a file, or anything else.
    static func standardErrorIsATerminal() -> Bool {
        isatty(STDERR_FILENO) == 1
    }

    /// Writes text to this binary's own standard error, verbatim.
    ///
    /// - Parameter text: The text to write. Nothing is added and nothing is
    ///   removed, so a caller that wants a line ending writes one.
    static func writeToStandardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// A Noora pipeline that hands every byte to a ``TerminalOutput`` sink.
///
/// Noora writes through `StandardPipelining`, and this layer writes through a
/// closure a test can point at a buffer. This adapter is the join between the
/// two, and it is the reason no Noora default descriptor is ever reached.
private struct SinkPipeline: StandardPipelining {
    /// Receives every byte Noora writes, verbatim.
    let sink: @Sendable (String) -> Void

    /// Hands one piece of Noora's output to ``sink``.
    ///
    /// - Parameter content: The bytes Noora wrote, terminators and escape
    ///   sequences included.
    func write(content: String) {
        sink(content)
    }
}
