import Foundation
import Synchronization
import Testing

@testable import acp_client

// These tests cover `TerminalOutput`, the stderr terminal layer of
// `cli-plan.md` §5 and §8, with one test for each acceptance row of the card.
//
// This file does not import `FoundationModelsACP`, and it must not. The wire
// package exports a `TerminalOutput` of its own — the ACP model of an
// agent-owned terminal's output — so importing both packages here makes the
// name ambiguous. The logger test needs no ACP type by name: it reads
// `TerminalOutput.logger` and calls `log(_:)` on what comes back.
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

/// A thread-safe text buffer that stands for standard error.
///
/// Noora's spinner draws from a timer thread of its own while the test body
/// runs, so the capture cannot be a plain `String`.
private final class StandardErrorBuffer: Sendable {
    /// Every chunk the sink received, in order.
    private let chunks = Mutex<[String]>([])

    /// Records one chunk exactly as the sink received it.
    ///
    /// - Parameter chunk: The text to record, with nothing added and nothing
    ///   removed.
    func append(_ chunk: String) {
        chunks.withLock { $0.append(chunk) }
    }

    /// Every byte written so far, end to end.
    var text: String {
        chunks.withLock { $0.joined() }
    }
}

/// A ``TerminalOutput`` over a buffer sink, and the buffer it writes to.
private struct TerminalOutputHarness {
    /// Everything the layer wrote.
    let buffer: StandardErrorBuffer

    /// The value under test.
    let output: TerminalOutput

    /// Builds the layer over a fresh buffer.
    ///
    /// - Parameters:
    ///   - verbosity: The verbosity to build the layer with.
    ///   - standardErrorIsATerminal: The answer the injected terminal reading
    ///     gives, which stands in for `isatty` on file descriptor 2.
    init(verbosity: TerminalVerbosity, standardErrorIsATerminal: Bool) {
        let buffer = StandardErrorBuffer()
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

@Suite("acp-client stderr terminal layer")
struct TerminalOutputTests {
    /// `cli-plan.md` §5 keeps Noora behind one file, so a later swap costs one
    /// file. The scan walks the whole executable target.
    @Test("exactly one file of the executable target imports Noora")
    func exactlyOneFileImportsNoora() throws {
        let files = try RepositoryFile.swiftSourceFiles(under: "Sources/acp-client")
        try #require(!files.isEmpty, "The scan found no Swift files below Sources/acp-client/.")

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
}
