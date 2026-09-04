import Synchronization
import Testing

@testable import AcpClientCore

// These tests cover the prompt-source table of `cli-plan.md` §7, one test for
// each of its four rows.
//
// Every test injects both closures of `PromptSource`. No test reads the real
// standard input, for two reasons: a test process cannot make its own stdin a
// terminal, so two of the four rows are unreachable without injection; and a
// read of the real stdin would take the bytes the test runner owns.

@Suite("acp-client prompt source")
struct PromptSourceTests {
    /// The text an injected standard input gives, where the content itself
    /// does not matter to the row under test.
    private static let injectedStandardInput = "from standard input"

    /// The text an injected prompt argument gives.
    private static let injectedArgument = "write a haiku"

    /// Builds the value under test over one pair of injected readings.
    ///
    /// - Parameters:
    ///   - standardInputIsATerminal: What the injected terminal reading
    ///     answers.
    ///   - standardInput: What the injected read of standard input gives.
    /// - Returns: A prompt source that touches no real descriptor.
    private static func promptSource(
        standardInputIsATerminal: Bool,
        standardInput: @escaping @Sendable () -> String = { injectedStandardInput }
    ) -> PromptSource {
        PromptSource(
            isStandardInputATerminal: { standardInputIsATerminal },
            readStandardInput: standardInput
        )
    }

    /// §7 row 1: a prompt argument that is not `-` is the prompt.
    @Test("an argument that is not a dash is the prompt")
    func anArgumentIsThePrompt() throws {
        let source = Self.promptSource(standardInputIsATerminal: false)

        #expect(try source.prompt(from: Self.injectedArgument) == Self.injectedArgument)
    }

    /// §7 row 2: no prompt argument, and stdin is a pipe or a file, reads the
    /// prompt from standard input.
    @Test("no argument, with standard input a pipe, reads standard input")
    func noArgumentWithAPipeReadsStandardInput() throws {
        let source = Self.promptSource(standardInputIsATerminal: false)

        #expect(try source.prompt(from: nil) == Self.injectedStandardInput)
    }

    /// §7 row 3: no prompt argument, and stdin is a terminal, is the usage
    /// error the caller turns into exit 2.
    @Test("no argument, with standard input a terminal, throws")
    func noArgumentWithATerminalThrows() {
        let source = Self.promptSource(standardInputIsATerminal: true)

        #expect(throws: PromptSourceError.noPromptAndStdinIsATerminal) {
            _ = try source.prompt(from: nil)
        }
    }

    /// §7 row 4: the `-` argument reads standard input, a terminal included.
    ///
    /// The argument is the literal `"-"` rather than
    /// `PromptSource.standardInputArgument`, because §7 names that one
    /// character and this test is what pins it. Spelling the constant here
    /// would assert only that the value equals itself.
    @Test("a dash argument reads standard input, a terminal included")
    func aDashReadsStandardInputFromATerminal() throws {
        let source = Self.promptSource(standardInputIsATerminal: true)

        #expect(try source.prompt(from: "-") == Self.injectedStandardInput)
    }

    /// The read of standard input is verbatim: no trimming, and no newline
    /// added or removed.
    @Test("the read of standard input is verbatim")
    func theReadOfStandardInputIsVerbatim() throws {
        let verbatim = "a\n\nb\n"
        let source = Self.promptSource(standardInputIsATerminal: false, standardInput: { verbatim })

        #expect(try source.prompt(from: nil) == verbatim)
    }

    /// An argument wins over standard input, and it wins early: the read
    /// never runs, so a prompt given on the command line never consumes a
    /// pipe the caller meant for something else.
    @Test("an argument wins, and standard input is never read")
    func anArgumentLeavesStandardInputUnread() throws {
        let wasStandardInputRead = Mutex(false)
        let source = Self.promptSource(standardInputIsATerminal: false) {
            wasStandardInputRead.withLock { $0 = true }
            return Self.injectedStandardInput
        }

        #expect(try source.prompt(from: Self.injectedArgument) == Self.injectedArgument)
        #expect(wasStandardInputRead.withLock { $0 } == false)
    }
}
