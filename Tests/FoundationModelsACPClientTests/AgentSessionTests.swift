import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPClient
@testable import AcpClientCore

// These tests cover `AgentSession`, the connect-and-initialize seam that
// `run`, `probe` and `doctor` share.
//
// Every test drives the seam over `InMemoryTransport.pair()`, because the
// seam takes an injected transport and spawns nothing: the caller owns the
// agent process. That is the whole reason these are unit tests and not
// integration tests — no binary is started, and nothing waits on a pipe.
//
// Both packages export a type called `TerminalOutput`, and this file imports
// both, so the binary's terminal layer is named `AcpClientCore.TerminalOutput`
// in full. The wire package's `TerminalOutput` is the ACP model of an
// agent-owned terminal, and it has no part in these tests.
//
// Every test builds the terminal layer over a buffer sink, so the assertions
// read the bytes the layer wrote and the test process never touches the real
// standard error.

/// The path of the source file under test, from the repository root.
private let agentSessionSourcePath = "Sources/AcpClientCore/AgentSession.swift"

/// The name ``ScriptedStubAgent`` reports in its `initialize` answer.
private let stubAgentName = "stub-agent"

/// The reply text the stub agent streams during a prompt turn.
private let stubReplyText = "Hello from the stub."

/// The message id the stub agent stamps on its reply chunk.
private let stubMessageID = MessageId(rawValue: "agent-session-msg-1")

/// The relative `--cwd` value the tests resolve against the process working
/// directory. It names a directory of this repository, so a reader can see
/// that the value is a real path and not a token.
private let relativeCwd = "Sources"

/// The absolute `--cwd` value the tests pass through unchanged.
private let absoluteCwd = "/usr/share"

/// The one reply chunk the stub agent streams during a prompt turn.
private let stubReplyChunk = agentChunk(text: stubReplyText, message: stubMessageID.rawValue)

/// The update script the stub agent sends during one prompt turn: one reply
/// chunk, then the idle state that ends the turn.
private let replyThenIdle: [SessionUpdate] = [stubReplyChunk, idleState(stopReason: .endTurn)]

/// The update script that holds the reply chunk alone, with no turn end.
///
/// A `state_update` flushes the coalescing buffer synchronously, so a script
/// that carried the idle update would land its text under any cadence and
/// would prove nothing about the cadence the seam chose.
private let replyChunkAlone: [SessionUpdate] = [stubReplyChunk]

/// One malformed ndJSON line, which makes the connection's codec write a
/// diagnostic through the logger this seam gave it.
private let malformedLine = Data("this is not json\n".utf8)

/// An ``AgentSession`` over one end of an in-memory pair, with a
/// ``ScriptedStubAgent`` on the other end and a buffer standing for standard
/// error.
///
/// The injected terminal reading is always `false`: a test process cannot
/// make its own standard error a terminal, and nothing these tests assert
/// depends on that reading.
@MainActor
private struct AgentSessionHarness {
    /// Everything the terminal layer wrote, in the chunks the sink received.
    let buffer: ThreadSafeBuffer<String>

    /// The value under test.
    let session: AgentSession

    /// The agent-side connection. A test holds it so the far end of the pair
    /// outlives the test body.
    let agentConnection: AgentSideConnection

    /// The stubs the agent-side factory built. The factory runs one time, so
    /// the list holds one element.
    private let builtAgents: ThreadSafeBuffer<ScriptedStubAgent>

    /// The stub agent on the far end of the pair.
    var agent: ScriptedStubAgent? {
        builtAgents.elements.last
    }

    /// Builds the seam over a fresh pair, a fresh stub and a fresh buffer.
    ///
    /// - Parameters:
    ///   - script: The updates the stub sends during the prompt turn.
    ///   - elicitation: The elicitation the stub asks for at the start of the
    ///     prompt turn, or `nil` to ask for none.
    ///   - cwd: The `--cwd` value, or `nil` for the process working
    ///     directory.
    ///   - verbosity: The verbosity to build the terminal layer with.
    ///   - closeSessionError: The error the stub answers `session/close`
    ///     with.
    ///   - clock: The clock that schedules the container's coalesced flushes.
    init(
        script: [SessionUpdate] = [],
        elicitation: CreateElicitationRequest? = nil,
        cwd: String? = nil,
        verbosity: TerminalVerbosity = .normal,
        closeSessionError: RequestError = .methodNotFound("session/close"),
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let builtAgents = ThreadSafeBuffer<ScriptedStubAgent>()
        self.builtAgents = builtAgents
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            let stub = ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: script,
                elicitation: elicitation,
                closeSessionError: closeSessionError
            )
            builtAgents.append(stub)
            return stub
        }
        let buffer = ThreadSafeBuffer<String>()
        self.buffer = buffer
        session = await AgentSession(
            over: clientEnd,
            terminal: AcpClientCore.TerminalOutput(
                verbosity: verbosity,
                isStandardErrorATerminal: { false },
                sink: { buffer.append($0) }
            ),
            cwd: cwd,
            clock: clock
        )
    }

    /// Runs `initialize` and opens the session, which is what every caller of
    /// this seam does before it drives a turn.
    ///
    /// - Returns: The session id and its update stream.
    /// - Throws: Whatever the seam threw.
    func openedSession() async throws -> (SessionId, AsyncStream<SessionUpdate>) {
        _ = try await session.initialize()
        return try await session.openSession()
    }

    /// Sends one prompt to the stub agent.
    ///
    /// - Parameter sessionId: The session to prompt.
    /// - Throws: Whatever the connection threw.
    func prompt(_ sessionId: SessionId) async throws {
        _ = try await session.connection.prompt(
            PromptRequest(prompt: [textBlock("go")], sessionId: sessionId)
        )
    }

    /// Tears the connection down, as every exit path of the binary does.
    func teardown() async {
        await session.teardown()
        withExtendedLifetime(agentConnection) {}
    }
}

/// The absolute form of one repository-relative path, resolved against the
/// process working directory exactly as the seam resolves `--cwd`.
///
/// - Parameter relativePath: The path to resolve.
/// - Returns: The absolute path, as text.
private func absoluteForm(of relativePath: String) -> String {
    URL(
        fileURLWithPath: relativePath,
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ).standardizedFileURL.path
}

/// The seam takes a transport and drives the agent over it, so a unit test
/// reaches the whole `initialize` path with no process anywhere.
@MainActor @Test(.timeLimit(.minutes(1)))
func anAgentSessionInitializesOverTheInjectedTransport() async throws {
    let harness = await AgentSessionHarness()

    let response = try await harness.session.initialize()

    #expect(response.protocolVersion == ACPClient.supportedProtocolVersion)
    #expect(response.info.name == stubAgentName)
    await harness.teardown()
}

/// `cli-plan.md` §8 gives `--verbose` the session events, one line each, and
/// the answer to `initialize` is the first of them: it says who is on the far
/// end of the transport, and which protocol version that agent answered with.
@MainActor @Test(.timeLimit(.minutes(1)))
func initializeWritesOneEventNamingTheAgent() async throws {
    let harness = await AgentSessionHarness(verbosity: .verbose)

    _ = try await harness.session.initialize()

    let written = harness.buffer.text
    #expect(written.contains(stubAgentName), "the layer wrote \"\(written)\"")
    await harness.teardown()
}

/// The session the agent opened is the next session event. A person debugging
/// a foreign agent reads the id off `--verbose`, because §8 keeps standard
/// output for the answer text and gives it no session id at all.
@MainActor @Test(.timeLimit(.minutes(1)))
func openSessionWritesOneEventNamingTheSession() async throws {
    let harness = await AgentSessionHarness(verbosity: .verbose)

    _ = try await harness.openedSession()

    let written = harness.buffer.text
    #expect(written.contains(testSession.rawValue), "the layer wrote \"\(written)\"")
    await harness.teardown()
}

/// §8 gives a default run nothing on stderr until it fails, so the seam's own
/// events wait for `--verbose` exactly as the connection's diagnostics do.
@MainActor @Test(.timeLimit(.minutes(1)))
func theSeamWritesNoEventAtTheDefaultVerbosity() async throws {
    let harness = await AgentSessionHarness()

    _ = try await harness.openedSession()

    #expect(harness.buffer.elements.isEmpty, "the layer wrote \"\(harness.buffer.text)\"")
    await harness.teardown()
}

/// The caller owns the agent process, so this seam starts none, and the
/// absence of a spawn is observable rather than a matter of reading the
/// source.
///
/// Every process this package starts registers its pid in the shared
/// `ProcessRegistry.global` — see the header of `AgentProcess.swift` — and
/// deregisters it only after the teardown killed and reaped the group. So a
/// spawn this seam made would still be a member of that registry while the
/// seam is live.
///
/// The suite is serialized because that registry is process-wide: a test that
/// ran beside this one and spawned a process of its own could add a pid
/// between the snapshot and the assertion.
@Suite(.serialized)
struct AgentSessionSpawnTests {
    /// Building the seam, negotiating with `initialize`, and opening a
    /// session adds no member to the process registry.
    @MainActor @Test(.timeLimit(.minutes(1)))
    func drivingTheSeamRegistersNoProcess() async throws {
        let before = ProcessRegistry.global.registeredPids

        let harness = await AgentSessionHarness()
        _ = try await harness.openedSession()

        #expect(ProcessRegistry.global.registeredPids.subtracting(before).isEmpty)
        await harness.teardown()
    }
}

/// §8 wants each chunk written as it arrives, so the container this seam
/// builds coalesces nothing, and one streamed chunk lands in the container
/// with no flush of the test's own.
///
/// The manual clock is what makes the cadence observable with no wall-clock
/// reading. `ManualClock.sleep(until:tolerance:)` resumes at once when the
/// deadline is not later than the current time, so the scheduled flush of a
/// `.zero` cadence runs against a clock this test never moves forward, and
/// the flush of the 33 ms default never runs. The test therefore has no time
/// bound to tune and cannot be flaky.
@MainActor @Test(.timeLimit(.minutes(1)))
func aStreamedChunkLandsInTheContainerWithNoFlush() async throws {
    let harness = await AgentSessionHarness(script: replyChunkAlone, clock: ManualClock())

    let (sessionId, _) = try await harness.openedSession()
    try await harness.prompt(sessionId)

    let state = harness.session.container.session(for: sessionId)
    #expect(
        await eventually {
            state.messageContent(for: stubMessageID) == [textBlock(stubReplyText)]
        }
    )
    await harness.teardown()
}

/// The connection serves the declining wrapper, so an elicitation is refused
/// at once and says so on standard error, and the streamed update still
/// reaches the container behind the wrapper.
@MainActor @Test(.timeLimit(.minutes(1)))
func theServedClientDeclinesAndTheUpdateStillReachesTheContainer() async throws {
    let harness = await AgentSessionHarness(
        script: replyThenIdle,
        elicitation: ElicitationFixtures.formRequest(
            scope: .session(ElicitationFixtures.sessionScope)
        )
    )

    let (sessionId, _) = try await harness.openedSession()
    try await harness.prompt(sessionId)

    #expect(harness.buffer.text == "declined elicitation/create for form mode\n")
    let state = harness.session.container.session(for: sessionId)
    #expect(
        await eventually {
            state.flushPendingChunks()
            return state.messageContent(for: stubMessageID) == [textBlock(stubReplyText)]
        }
    )
    await harness.teardown()
}

/// The wire package drops updates for a session with no active subscriber, so
/// the subscription is live before `openSession()` returns. A chunk the agent
/// sends the moment the prompt lands therefore reaches the returned stream.
@MainActor @Test(.timeLimit(.minutes(1)))
func aChunkSentAsSoonAsThePromptLandsReachesTheReturnedStream() async throws {
    let harness = await AgentSessionHarness(script: replyThenIdle)

    let (sessionId, updates) = try await harness.openedSession()
    try await harness.prompt(sessionId)

    var iterator = updates.makeAsyncIterator()
    let first = try #require(await iterator.next())
    #expect(first == agentChunk(text: stubReplyText, message: stubMessageID.rawValue))
    await harness.teardown()
}

/// `--cwd` is the SESSION's working directory, so a relative value is made
/// absolute against the process working directory and sent as
/// `NewSessionRequest.cwd`. The process working directory itself never
/// changes.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRelativeCwdReachesNewSessionAsAnAbsolutePath() async throws {
    let processDirectory = FileManager.default.currentDirectoryPath
    let harness = await AgentSessionHarness(cwd: relativeCwd)

    _ = try await harness.openedSession()

    let agent = try #require(harness.agent)
    #expect(agent.lastWorkingDirectory?.rawValue == absoluteForm(of: relativeCwd))
    #expect(FileManager.default.currentDirectoryPath == processDirectory)
    await harness.teardown()
}

/// An absolute `--cwd` reaches `NewSessionRequest.cwd` unchanged.
@MainActor @Test(.timeLimit(.minutes(1)))
func anAbsoluteCwdReachesNewSessionUnchanged() async throws {
    let harness = await AgentSessionHarness(cwd: absoluteCwd)

    _ = try await harness.openedSession()

    let agent = try #require(harness.agent)
    #expect(agent.lastWorkingDirectory?.rawValue == absoluteCwd)
    await harness.teardown()
}

/// With no `--cwd`, the session's working directory is the process working
/// directory, which is the default `cli-plan.md` §6.1 states.
@MainActor @Test(.timeLimit(.minutes(1)))
func anAbsentCwdUsesTheProcessWorkingDirectory() async throws {
    let harness = await AgentSessionHarness()

    _ = try await harness.openedSession()

    let agent = try #require(harness.agent)
    #expect(agent.lastWorkingDirectory?.rawValue == FileManager.default.currentDirectoryPath)
    await harness.teardown()
}

/// The connection's own diagnostics go to the terminal layer, and the layer
/// owns standard error alone.
///
/// The connection logs only on an anomaly, so the test provokes one: a
/// malformed ndJSON line written into the far end of the pair makes the
/// codec write its diagnostic through the logger this seam gave it. No agent
/// connection serves that end, because the raw bytes are the whole point.
@MainActor @Test(.timeLimit(.minutes(1)))
func theLoggerWritesToTheTerminalLayerAndNeverToStandardOutput() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let buffer = ThreadSafeBuffer<String>()
    let session = await AgentSession(
        over: clientEnd,
        terminal: AcpClientCore.TerminalOutput(
            verbosity: .verbose,
            isStandardErrorATerminal: { false },
            sink: { buffer.append($0) }
        ),
        cwd: nil
    )

    try await agentEnd.write(malformedLine)

    #expect(await eventually { buffer.text.contains("malformed line") })
    let source = try RepositoryFile.read(relativePath: agentSessionSourcePath)
    for name in ["print(", "standardOutput", "STDOUT_FILENO", "fputs", "fwrite"] {
        #expect(!source.contains(name), "AgentSession.swift names \"\(name)\".")
    }
    await session.teardown()
}

/// A `session/close` the agent does not implement is not a failure of the
/// run: the wire makes the method optional, and the binary has already had
/// its answer. The refusal is reported at `--verbose` and swallowed
/// otherwise, so no exit path turns on it.
@MainActor @Test(.timeLimit(.minutes(1)))
func aMethodNotFoundCloseIsReportedAsUnanswered() async throws {
    let harness = await AgentSessionHarness(verbosity: .verbose)
    let (sessionId, _) = try await harness.openedSession()

    await harness.session.closeSession(sessionId)

    #expect(harness.buffer.text.contains("session/close was not answered"))
    await harness.teardown()
}

/// An agent that answers `session/close` with any other error DID answer, so
/// the event line must report a failure and must not say that the call went
/// unanswered. `invalidParams` stands for every such answer.
@MainActor @Test(.timeLimit(.minutes(1)))
func anyOtherCloseErrorIsReportedAsAFailure() async throws {
    let harness = await AgentSessionHarness(
        verbosity: .verbose,
        closeSessionError: .invalidParams
    )
    let (sessionId, _) = try await harness.openedSession()

    await harness.session.closeSession(sessionId)

    #expect(harness.buffer.text.contains("session/close failed"))
    #expect(!harness.buffer.text.contains("was not answered"))
    await harness.teardown()
}
