import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The plumbing the later CLI rows of `cli-plan.md` §14 stand on: the built
// `acp-client` binary beside this test bundle, the bounded runner that drives
// it, and the three shell-script stub agents.
//
// This file asserts the plumbing and nothing else. `run`, `probe` and `doctor`
// are not wired yet, so the only subcommand-tree behaviour asserted here is
// `--version`, which ArgumentParser already answers.

/// The number of minutes each suite in this file allows itself.
///
/// Every test here spawns a real process, so a loaded machine must not fail a
/// suite that is only slow. The bound each test really rests on is
/// ``TransportTestDeadline/limit``; this one is the backstop the suite keeps so
/// that a wedged run ends rather than holding the whole package open.
private let processSuiteTimeLimitMinutes = 5

/// How many seconds ``stubAgentSilenceLimit`` runs for.
private let stubAgentSilenceLimitSeconds = 2

/// The longest a stub agent gets to answer before a test calls it silent.
///
/// Shorter than ``TransportTestDeadline/limit``, because the silent-agent test
/// waits out the whole window on purpose and a suite must not pay ten seconds
/// for one negative assertion.
private let stubAgentSilenceLimit: Duration = .seconds(stubAgentSilenceLimitSeconds)

/// One `initialize` request as raw ndJSON, newline included.
///
/// The tests that read an agent's RAW stdout cannot use
/// ``ClientSideConnection``, because a connection owns the byte stream it
/// decodes. They write this frame instead, which is what any ACP client sends
/// first.
private let rawInitializeFrame = Data(
    """
    {"id":1,"jsonrpc":"2.0","method":"initialize","params":{}}

    """.utf8
)

/// Reads the first newline-terminated line an agent writes to its stdout.
///
/// The wait is bounded, so an agent that writes nothing fails the test that
/// asked rather than hanging the suite.
///
/// - Parameters:
///   - transport: The transport wired to the agent's stdout.
///   - limit: The longest time to wait for the newline.
/// - Returns: The line without its newline, or `nil` when the limit ended
///   first or the agent closed its stdout with no complete line.
private func firstStdoutLine(
    of transport: any ACPTransport,
    within limit: Duration = TransportTestDeadline.limit
) async -> String? {
    await withTaskGroup(of: String?.self) { group in
        group.addTask { await lineBeforeEndOfStream(of: transport) }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let line = await group.next() ?? nil
        group.cancelAll()
        return line
    }
}

/// Accumulates `transport`'s bytes until the first newline stands in them.
///
/// - Parameter transport: The transport wired to the agent's stdout.
/// - Returns: The first line without its newline, or `nil` when the stream
///   ended, threw, or was cancelled with no complete line in hand.
private func lineBeforeEndOfStream(of transport: any ACPTransport) async -> String? {
    var buffer = Data()
    do {
        for try await chunk in transport.bytes {
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            }
        }
    } catch {
        return nil
    }
    return nil
}

/// The built `acp-client` binary and the bounded runner that drives it.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns a real process.
@Suite(
    "The acp-client binary locator and runner",
    .serialized,
    .timeLimit(.minutes(processSuiteTimeLimitMinutes))
)
struct CLITestSupportTests {
    /// The number of dot-separated numbers a semantic version carries.
    ///
    /// The binary's own `AcpClientVersion.current` cannot be read from here.
    /// SwiftPM builds an executable product for this test bundle to spawn, and
    /// it does not publish that target's module to another package, so the
    /// assertion below is on the SHAPE the unit suite's
    /// `AcpClientVersionTests` pins the constant to.
    private static let semanticVersionComponentCount = 3

    /// The text the two drain tests put through their pipe.
    private static let drainedText = "one line of standard error\n"

    /// How many milliseconds ``openWriterGrace`` runs for.
    private static let openWriterGraceMilliseconds = 200

    /// The grace the still-open-writer drain test waits out in full.
    ///
    /// Short on purpose: that test spends the whole of it, and a suite must not
    /// pay the runner's own grace for one negative assertion.
    private static let openWriterGrace: Duration = .milliseconds(openWriterGraceMilliseconds)

    /// The grace the closed-writer drain test must NOT wait out.
    ///
    /// Long on purpose: the claim there is that the drain ends at the end of
    /// file rather than at its deadline, and a short grace would make a weak
    /// claim of it.
    private static let closedWriterGrace: Duration = TransportTestDeadline.limit

    /// The locator finds an executable file, which is what proves that the
    /// test target's dependency on the `acp-client` product made SwiftPM build
    /// the binary beside this test bundle.
    @Test func theLocatorFindsTheBuiltExecutable() throws {
        let binary = try acpClientBinaryURL()

        #expect(binary.lastPathComponent == acpClientExecutableName)
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
    }

    /// `--version` exits 0, writes the version to stdout, and writes nothing
    /// to stderr.
    @Test func theVersionFlagPrintsTheVersionAndExitsZero() async throws {
        let result = try await runAcpClient(["--version"])

        #expect(result.exitCode == 0)
        let reported = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = reported.split(separator: ".")
        #expect(components.count == Self.semanticVersionComponentCount, "stdout was \"\(reported)\"")
        #expect(
            components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) },
            "stdout was \"\(reported)\""
        )
        #expect(result.standardError.isEmpty)
    }

    /// The drain hands back what arrived while a writer still holds the pipe.
    ///
    /// This is the claim the whole runner rests on. A run that LEAKED a process
    /// leaves that process holding the harness's own stderr write end open, and
    /// a blocking read of that pipe never returns: the leak would then read as a
    /// wedged suite rather than as the failed expectation the test came to make.
    @Test func theDrainGivesBackWhatArrivedWhileAWriterStillHoldsThePipe() async throws {
        let pipe = Pipe()
        let drain = PipeDrain(pipe.fileHandleForReading)
        defer { drain.tearDown() }
        defer { try? pipe.fileHandleForWriting.close() }
        try pipe.fileHandleForWriting.write(contentsOf: Data(Self.drainedText.utf8))

        let clock = ContinuousClock()
        let started = clock.now
        let drained = await drain.bytes(waitingUpTo: Self.openWriterGrace)
        let elapsed = clock.now - started

        #expect(String(decoding: drained, as: UTF8.self) == Self.drainedText)
        #expect(
            elapsed >= Self.openWriterGrace,
            "the drain gave up after \(elapsed), before its grace of \(Self.openWriterGrace) ended"
        )
    }

    /// The drain ends the moment the last writer closes, and waits out no grace.
    ///
    /// It is the other half of the claim above: the deadline is what a leak
    /// costs, and a run that left nothing behind pays none of it.
    @Test func theDrainEndsWhenTheLastWriterCloses() async throws {
        let pipe = Pipe()
        let drain = PipeDrain(pipe.fileHandleForReading)
        defer { drain.tearDown() }
        try pipe.fileHandleForWriting.write(contentsOf: Data(Self.drainedText.utf8))
        try pipe.fileHandleForWriting.close()

        let clock = ContinuousClock()
        let started = clock.now
        let drained = await drain.bytes(waitingUpTo: Self.closedWriterGrace)
        let elapsed = clock.now - started

        #expect(String(decoding: drained, as: UTF8.self) == Self.drainedText)
        #expect(
            elapsed < Self.closedWriterGrace,
            "the drain waited \(elapsed), the whole grace of \(Self.closedWriterGrace)"
        )
    }
}

/// The three shell-script stub agents, each checked directly with
/// ``AgentProcess`` rather than through `acp-client`.
///
/// Serialized and time-limited, for the same reason as every other suite here.
@Suite(
    "The CLI stub agents",
    .serialized,
    .timeLimit(.minutes(processSuiteTimeLimitMinutes))
)
struct StubAgentTests {
    /// The reply text the prompt-turn test asks the well behaved agent for.
    private static let chosenAnswer = "The stub agent answered."

    /// The well behaved agent answers `initialize` and `session/new` with
    /// ndJSON the wire decodes, and it leaves no process behind.
    @MainActor
    @Test func theWellBehavedAgentAnswersInitializeAndNewSession() async throws {
        let script = try makeWellBehavedAgent(answer: Self.chosenAnswer, stopReason: .endTurn)
        defer { removeAgentScript(script) }
        let process = try AgentProcess(command: stubAgentShellCommand, arguments: [script])
        let pid = try #require(process.processIdentifier)

        let client = SwiftUIACPClient()
        let connection = await client.connect(over: process.transport)
        let initialized = try await connection.initialize(makeInitializeRequest())
        #expect(initialized.protocolVersion == ACPClient.supportedProtocolVersion)
        #expect(initialized.info.name == stubAgentName)

        let cwd = try #require(AbsolutePath(rawValue: "/"))
        let session = try await connection.newSession(NewSessionRequest(cwd: cwd))
        #expect(session.sessionId == stubAgentSessionID)

        await connection.close()
        #expect(await eventually { !processExists(pid) })
    }

    /// The well behaved agent streams the chosen answer as
    /// `agent_message_chunk` updates and ends the turn with the chosen stop
    /// reason.
    @MainActor
    @Test func theWellBehavedAgentStreamsTheChosenAnswerAndStopReason() async throws {
        let script = try makeWellBehavedAgent(answer: Self.chosenAnswer, stopReason: .maxTokens)
        defer { removeAgentScript(script) }
        let process = try AgentProcess(command: stubAgentShellCommand, arguments: [script])
        let pid = try #require(process.processIdentifier)

        let client = SwiftUIACPClient()
        let connection = try await initializedConnection(for: client, over: process.transport)
        let cwd = try #require(AbsolutePath(rawValue: "/"))
        let session = try await connection.newSession(NewSessionRequest(cwd: cwd))

        let replyLanded = try await promptTurnLandsReply(
            over: connection,
            client: client,
            sessionId: session.sessionId,
            messageID: stubAgentMessageID,
            expectedText: Self.chosenAnswer
        )
        #expect(replyLanded)
        #expect(client.session(for: session.sessionId).lastStopReason == .maxTokens)

        await connection.close()
        #expect(await eventually { !processExists(pid) })
    }

    /// The banner agent writes a first stdout line that is not JSON, which is
    /// the condition the `doctor` stdout-purity check will find.
    @Test func theBannerAgentWritesANonJSONFirstLine() async throws {
        let script = try makeBannerOnStdoutAgent()
        defer { removeAgentScript(script) }
        let process = try AgentProcess(command: stubAgentShellCommand, arguments: [script])
        let pid = try #require(process.processIdentifier)

        let firstLine = try #require(await firstStdoutLine(of: process.transport))

        #expect(firstLine == stubAgentBannerLine)
        #expect((try? JSONSerialization.jsonObject(with: Data(firstLine.utf8))) == nil)

        process.shutdown()
        #expect(await eventually { !processExists(pid) })
    }

    /// The silent agent reads its stdin and never answers `initialize`, and it
    /// is gone after teardown.
    @Test func theSilentAgentNeverAnswersAndLeavesNoProcess() async throws {
        let script = try makeSilentAgent()
        defer { removeAgentScript(script) }
        let process = try AgentProcess(command: stubAgentShellCommand, arguments: [script])
        let pid = try #require(process.processIdentifier)

        try await process.transport.write(rawInitializeFrame)
        let answer = await firstStdoutLine(of: process.transport, within: stubAgentSilenceLimit)

        #expect(answer == nil)

        process.shutdown()
        #expect(await eventually { !processExists(pid) })
    }
}
