import Foundation
import FoundationModelsExtras
import Testing

@testable import AcpClientCore

// These tests cover `TerminalOutput`, the stderr terminal layer of
// `cli-plan.md` §5 and §8, with one test for each acceptance row of the card.
//
// This file does not import `FoundationModelsACP`, and it must not. The wire
// package exports a `TerminalOutput` of its own — the ACP model of an
// agent-owned terminal's output — so importing both packages here makes the
// name ambiguous. The logger test needs no ACP type by name: it reads
// `TerminalOutput.logger` and calls `log(_:)` on what comes back.
//
// `FoundationModelsExtras` is imported for `DoctorReport`, `HealthCheck` and
// `PlainTextDoctorRenderer`. The doctor-report tests build one report and
// drive it through both paths of ``TerminalOutput/doctorReport(_:)``: the
// plain path is compared byte for byte with the Extras renderer's own drawing,
// and the terminal path is read for the rows and for Noora's table border.
//
// Every test builds the layer over a buffer sink and over a chosen answer to
// "is standard error a terminal", and then asserts the bytes the buffer holds.
// A test process cannot make its own standard error a terminal, and it must
// not write to the real one either, so both readings are injected.
//
// The terminal rows drive the real Noora progress step, and the assertions
// name the bytes Noora draws: the success mark, the error mark, and the
// cursor escape of the in-place renderer. Those bytes are the proof that both
// of Noora's pipelines reach this layer's sink, and that Noora's terminal gate
// took the injected answer rather than reading a descriptor of its own.
//
// What these tests do NOT prove is that stdout stayed clean. A buffer sink
// cannot see a byte that Noora sent straight to file descriptor 1, and a grep
// of the sources cannot see a Noora default that starts writing there in a
// later release. That proof is a file-descriptor test over the real binary,
// and it belongs to the `--frames` integration task ^3CAT35C: stdout holds the
// answer bytes only, while a spinner runs.

/// A ``TerminalOutput`` over a buffer sink, and the buffer it writes to.
///
/// Noora's spinner draws from a timer thread of its own while the test body
/// runs, so the buffer that stands for standard error is a
/// ``ThreadSafeBuffer`` and not a plain `String`.
private struct TerminalOutputHarness {
    /// Everything the layer wrote, in the chunks the sink received.
    let buffer: ThreadSafeBuffer<String>

    /// The value under test.
    let output: TerminalOutput

    /// Builds the layer over a fresh buffer.
    ///
    /// - Parameters:
    ///   - verbosity: The verbosity to build the layer with.
    ///   - standardErrorIsATerminal: The answer the injected terminal reading
    ///     gives, which stands in for `isatty` on file descriptor 2.
    init(verbosity: TerminalVerbosity, standardErrorIsATerminal: Bool) {
        let buffer = ThreadSafeBuffer<String>()
        self.buffer = buffer
        output = TerminalOutput(
            verbosity: verbosity,
            isStandardErrorATerminal: { standardErrorIsATerminal },
            sink: { buffer.append($0) }
        )
    }
}

/// The failure a test body throws, so an assertion can tell it from any other.
private struct SpinnerBodyFailure: Error {}

/// The text the terminal tests share.
private enum SpinnerText {
    /// The neutral label the tests give the spinner.
    ///
    /// It carries no claim about what the agent is doing, which is what §8
    /// asks of the label and of the closing line that repeats it.
    static let label = "Waiting for the agent"

    /// The value a test body returns, so an assertion can see it came back.
    static let bodyValue = "the body value"

    /// The line a test hands to ``TerminalOutput/event(_:)``.
    static let event = "session/update requested"

    /// The line a test hands to ``TerminalOutput/error(_:)``.
    static let failure = "the agent stopped"

    /// The line a test hands to ``TerminalOutput/frame(_:)``.
    ///
    /// It carries a direction mark and an ndJSON message, because that is what
    /// the `--frames` tee gives the layer.
    static let frame = #">> {"id":1,"jsonrpc":"2.0","method":"initialize"}"#

    /// The mark Noora's progress step draws when the task returned.
    ///
    /// The interactive path sends it to `standardPipelines.output`, so this
    /// mark in the buffer is the proof that the output pipeline is this
    /// layer's sink and not Noora's `print`-backed default.
    static let successMark = "✔︎"

    /// The mark Noora's progress step draws when the task threw.
    ///
    /// The interactive path sends it to `standardPipelines.error`, so this
    /// mark in the buffer is the proof that the error pipeline is this
    /// layer's sink too.
    static let errorMark = "⨯"

    /// The escape sequence Noora's in-place renderer writes before it redraws.
    ///
    /// Only the interactive path of the progress step goes through that
    /// renderer. The non-interactive path writes plain lines and no escape at
    /// all, so this sequence in the buffer is the proof that Noora's
    /// `Terminal` was built interactive.
    static let cursorToLineStart = "\u{001B}[1G"

    /// The environment variable that makes Noora's own terminal gate answer
    /// `false`, whatever the descriptors are.
    ///
    /// `Terminal.isInteractive()` reads this name before it reads
    /// `STDIN_FILENO`. A test that sets it holds Noora's default answer at
    /// `false` on every machine, so an assertion that the drawing still
    /// happened is an assertion that the default was never asked.
    static let nooraNonInteractiveVariable = "NO_TTY"
}

/// The report the doctor-report tests draw, and the text its rows carry.
///
/// One row of each status, so the drawing has a passing row, a row with a
/// fix under a warning, and a row with a fix under an error: every shape the
/// table and the plain rendering draw differently.
///
/// Every text is short on purpose. Noora lays its table out against the width
/// of standard OUTPUT, which is a pipe under the test runner, so the layout
/// falls back to 80 columns and cuts each cell that does not fit with an
/// ellipsis. Texts this short fit whole at that width, so the table test can
/// read each one back. The cut is Noora's layout and not this layer's, and
/// the agent CLI of this family draws the same table.
private enum DoctorReportFixture {
    /// The name of the row that passed.
    static let passedName = "command"

    /// The message of the row that passed.
    static let passedMessage = "resolved"

    /// The name of the row that warned.
    static let warnedName = "teardown"

    /// The message of the row that warned.
    static let warnedMessage = "still running"

    /// The fix of the row that warned.
    static let warnedFix = "end the agent"

    /// The name of the row that failed.
    static let failedName = "initialize"

    /// The message of the row that failed.
    static let failedMessage = "no answer"

    /// The fix of the row that failed.
    static let failedFix = "answer in time"

    /// The group every row belongs to.
    static let category = "agent"

    /// Every text a drawing of ``report`` must carry, whatever its shape.
    static let rowTexts = [
        passedName, passedMessage,
        warnedName, warnedMessage, warnedFix,
        failedName, failedMessage, failedFix,
    ]

    /// The status marks the table draws, one for each status of ``report``.
    ///
    /// They are the marks the agent CLI of this family draws in its own
    /// doctor table, so the two CLIs draw alike: the passing mark, the
    /// warning mark and the failure mark.
    static let statusMarks = ["✔︎", "!", "⨯"]

    /// The vertical border Noora's rounded table style draws between two
    /// cells.
    ///
    /// The plain rendering holds no such character, so this one in the
    /// buffer is the proof that the terminal path drew a table and not the
    /// plain text.
    static let tableBorder = "│"

    /// The report, one row of each status.
    static let report = DoctorReport(checks: [
        .ok(name: passedName, message: passedMessage, category: category),
        .warning(name: warnedName, message: warnedMessage, fix: warnedFix, category: category),
        .error(name: failedName, message: failedMessage, fix: failedFix, category: category),
    ])
}

@Suite("acp-client stderr terminal layer")
struct TerminalOutputTests {
    /// `cli-plan.md` §5 keeps Noora behind one file, so a later swap costs one
    /// file. The scan walks both targets of the command-line client, so a
    /// second importer cannot hide in the thin executable.
    @Test("exactly one file of the command-line client imports Noora")
    func exactlyOneFileImportsNoora() throws {
        let directories = RepositoryFile.commandLineClientDirectories
        let files = try RepositoryFile.swiftSourceFiles(underAnyOf: directories)
        try #require(!files.isEmpty, "The scan found no Swift files below \(directories).")

        let importers = try files
            .filter { try SwiftImports.modules(in: $0).contains("Noora") }
            .map(\.lastPathComponent)
            .sorted()

        #expect(importers == ["TerminalOutput.swift"])
    }

    /// Noora's output pipeline is this layer's sink, not its `print`-backed
    /// default, so the success line of the progress step reaches stderr.
    @Test("the progress step's success line reaches the injected sink")
    func theSuccessLineReachesTheSink() async throws {
        let harness = TerminalOutputHarness(verbosity: .normal, standardErrorIsATerminal: true)

        _ = try await harness.output.withSpinner(SpinnerText.label) { _ in
            SpinnerText.bodyValue
        }

        #expect(harness.buffer.text.contains(SpinnerText.successMark))
    }

    /// Noora's error pipeline is this layer's sink too, so the error line of
    /// the progress step reaches stderr rather than Noora's own descriptor.
    @Test("the progress step's error line reaches the injected sink")
    func theErrorLineReachesTheSink() async throws {
        let harness = TerminalOutputHarness(verbosity: .normal, standardErrorIsATerminal: true)

        await #expect(throws: SpinnerBodyFailure.self) {
            try await harness.output.withSpinner(SpinnerText.label) { _ -> String in
                throw SpinnerBodyFailure()
            }
        }

        #expect(harness.buffer.text.contains(SpinnerText.errorMark))
    }

    /// Noora's own `Terminal.isInteractive()` reads standard input, and §8
    /// gates on standard error. The `Terminal` value takes the injected
    /// reading, so a piped prompt on standard input does not turn the drawing
    /// off on a real terminal.
    ///
    /// The variable this test sets is what makes it discriminating. It holds
    /// Noora's own gate at `false` for the length of the test, on a developer's
    /// terminal and on a CI runner alike. A `Terminal` built from Noora's
    /// defaults would then take the non-interactive path, which writes plain
    /// lines and no escape at all, and this assertion would fail.
    @Test("the progress step draws in place while Noora's own gate says otherwise")
    func theProgressStepDrawsInPlaceOnAnInjectedTerminal() async throws {
        setenv(SpinnerText.nooraNonInteractiveVariable, "1", 1)
        defer { unsetenv(SpinnerText.nooraNonInteractiveVariable) }
        let harness = TerminalOutputHarness(verbosity: .normal, standardErrorIsATerminal: true)

        _ = try await harness.output.withSpinner(SpinnerText.label) { _ in
            SpinnerText.bodyValue
        }

        #expect(harness.buffer.text.contains(SpinnerText.cursorToLineStart))
    }

    /// §8 gives a pipe or a file nothing at all. The body still runs, and the
    /// line closure it is handed is a working no-op.
    @Test("withSpinner writes nothing and still runs the body outside a terminal")
    func withSpinnerWritesNothingOutsideATerminal() async throws {
        let harness = TerminalOutputHarness(verbosity: .normal, standardErrorIsATerminal: false)

        let value = try await harness.output.withSpinner(SpinnerText.label) { reportToolName in
            reportToolName(SpinnerText.event)
            return SpinnerText.bodyValue
        }

        #expect(value == SpinnerText.bodyValue)
        #expect(harness.buffer.text.isEmpty)
    }

    /// §8 gives `--quiet` nothing but errors, in a terminal too.
    @Test("withSpinner writes nothing at quiet, in a terminal too")
    func withSpinnerWritesNothingAtQuietInATerminal() async throws {
        let harness = TerminalOutputHarness(verbosity: .quiet, standardErrorIsATerminal: true)

        _ = try await harness.output.withSpinner(SpinnerText.label) { _ in
            SpinnerText.bodyValue
        }

        #expect(harness.buffer.text.isEmpty)
    }

    /// The drawing is decoration around the body, so the body's value comes
    /// back unchanged through the drawing path as well.
    @Test("withSpinner returns the body's value in a terminal")
    func withSpinnerReturnsTheBodyValueInATerminal() async throws {
        let harness = TerminalOutputHarness(verbosity: .normal, standardErrorIsATerminal: true)

        let value = try await harness.output.withSpinner(SpinnerText.label) { _ in
            SpinnerText.bodyValue
        }

        #expect(value == SpinnerText.bodyValue)
    }

    /// The body's failure is the caller's failure, and the drawing must not
    /// swallow it.
    @Test("withSpinner rethrows the body's error outside a terminal")
    func withSpinnerRethrowsOutsideATerminal() async throws {
        let harness = TerminalOutputHarness(verbosity: .normal, standardErrorIsATerminal: false)

        await #expect(throws: SpinnerBodyFailure.self) {
            try await harness.output.withSpinner(SpinnerText.label) { _ -> String in
                throw SpinnerBodyFailure()
            }
        }
    }

    /// The same, through the drawing path.
    @Test("withSpinner rethrows the body's error in a terminal")
    func withSpinnerRethrowsInATerminal() async throws {
        let harness = TerminalOutputHarness(verbosity: .normal, standardErrorIsATerminal: true)

        await #expect(throws: SpinnerBodyFailure.self) {
            try await harness.output.withSpinner(SpinnerText.label) { _ -> String in
                throw SpinnerBodyFailure()
            }
        }
    }

    /// §8 gives a default run nothing on stderr until it fails, so the session
    /// events wait for `--verbose`.
    @Test("event writes nothing at normal")
    func eventWritesNothingAtNormal() {
        let harness = TerminalOutputHarness(verbosity: .normal, standardErrorIsATerminal: true)

        harness.output.event(SpinnerText.event)

        #expect(harness.buffer.text.isEmpty)
    }

    /// §8 gives `--quiet` nothing but errors, and an event is not an error.
    @Test("event writes nothing at quiet, in a terminal too")
    func eventWritesNothingAtQuietInATerminal() {
        let harness = TerminalOutputHarness(verbosity: .quiet, standardErrorIsATerminal: true)

        harness.output.event(SpinnerText.event)

        #expect(harness.buffer.text.isEmpty)
    }

    /// §8 gives `--verbose` the session events, one line each.
    @Test("event writes one line at verbose")
    func eventWritesOneLineAtVerbose() {
        let harness = TerminalOutputHarness(verbosity: .verbose, standardErrorIsATerminal: false)

        harness.output.event(SpinnerText.event)

        #expect(harness.buffer.text == SpinnerText.event + "\n")
    }

    /// `cli-plan.md` §6.1 makes `--frames` a debugging switch and not a
    /// verbosity level, so a teed line goes out at every verbosity — `--quiet`
    /// among them — and outside a terminal as readily as in one.
    @Test(
        "frame writes one line at every verbosity",
        arguments: [TerminalVerbosity.quiet, .normal, .verbose]
    )
    func frameWritesOneLineAtEveryVerbosity(verbosity: TerminalVerbosity) {
        let harness = TerminalOutputHarness(
            verbosity: verbosity,
            standardErrorIsATerminal: false
        )

        harness.output.frame(SpinnerText.frame)

        #expect(harness.buffer.text == SpinnerText.frame + "\n")
    }

    /// §8 gives `--quiet` its errors, because a run that fails silently is a
    /// run a person cannot debug.
    @Test("error writes one line at quiet")
    func errorWritesOneLineAtQuiet() {
        let harness = TerminalOutputHarness(verbosity: .quiet, standardErrorIsATerminal: false)

        harness.output.error(SpinnerText.failure)

        #expect(harness.buffer.text == SpinnerText.failure + "\n")
    }

    /// A person who asked for silence asked for silence, so `--quiet` wins.
    @Test("--quiet together with --verbose resolves to quiet")
    func quietWinsOverVerbose() {
        #expect(TerminalVerbosity(quiet: true, verbose: true) == .quiet)
    }

    /// The connection's diagnostics are session events, so the bridge lands
    /// them where `--verbose` lands its own lines, and never on stdout.
    @Test("the logger bridge writes one line at verbose")
    func theLoggerBridgeWritesOneLineAtVerbose() {
        let harness = TerminalOutputHarness(verbosity: .verbose, standardErrorIsATerminal: false)

        harness.output.logger.log(SpinnerText.event)

        #expect(harness.buffer.text == SpinnerText.event + "\n")
    }

    /// The bridge is `event(_:)`, so it keeps `event(_:)`'s silence.
    @Test("the logger bridge writes nothing at normal")
    func theLoggerBridgeWritesNothingAtNormal() {
        let harness = TerminalOutputHarness(verbosity: .normal, standardErrorIsATerminal: false)

        harness.output.logger.log(SpinnerText.event)

        #expect(harness.buffer.text.isEmpty)
    }

    /// `cli-plan.md` §8 sends the human doctor report to standard error, and a
    /// pipe or a file gets the Extras plain rendering: the same bytes the
    /// renderer draws on its own, so a script reads a stable report. The
    /// report is the output of `doctor`, so `--quiet` does not silence it.
    @Test(
        "the doctor report outside a terminal is the plain rendering, at every verbosity",
        arguments: [TerminalVerbosity.quiet, .normal, .verbose]
    )
    func theDoctorReportOutsideATerminalIsThePlainRendering(verbosity: TerminalVerbosity) {
        let harness = TerminalOutputHarness(
            verbosity: verbosity,
            standardErrorIsATerminal: false
        )

        harness.output.doctorReport(DoctorReportFixture.report)

        #expect(
            harness.buffer.text == PlainTextDoctorRenderer().render(DoctorReportFixture.report)
        )
    }

    /// `cli-plan.md` §5 gives the doctor report to the terminal layer when
    /// standard error is a terminal, and the layer draws Noora's table: every
    /// row with its status mark, its message and its fix, inside the table
    /// border. The report is the output of `doctor`, so `--quiet` does not
    /// silence it.
    @Test(
        "the doctor report in a terminal is a table holding every row, at every verbosity",
        arguments: [TerminalVerbosity.quiet, .normal, .verbose]
    )
    func theDoctorReportInATerminalIsATable(verbosity: TerminalVerbosity) {
        let harness = TerminalOutputHarness(
            verbosity: verbosity,
            standardErrorIsATerminal: true
        )

        harness.output.doctorReport(DoctorReportFixture.report)

        let drawn = harness.buffer.text
        for rowText in DoctorReportFixture.rowTexts + DoctorReportFixture.statusMarks {
            #expect(drawn.contains(rowText), "the table holds no \"\(rowText)\": \"\(drawn)\"")
        }
        #expect(
            drawn.contains(DoctorReportFixture.tableBorder),
            "the drawing holds no table border: \"\(drawn)\""
        )
    }
}
