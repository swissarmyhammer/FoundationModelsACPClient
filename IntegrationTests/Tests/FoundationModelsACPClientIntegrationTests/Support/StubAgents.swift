import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The foreign agents this suite spawns, as `/bin/sh` scripts.
//
// A script is the right shape for a foreign agent: it knows nothing about this
// runtime, so a test that drives one proves the WIRE is the interface. It is
// also the only shape available. The unit suite's `ScriptedStubAgent` is a type
// inside `FoundationModelsACPClientTests`, and a Swift test target publishes no
// type to a test target in an other package, so this suite cannot reuse it.
//
// `cli-plan.md` §14 needs three of them, and later CLI tasks add more. Each
// builder here writes one script into a temporary directory and gives back its
// absolute path; the caller removes the file with ``removeAgentScript(_:)``.

// MARK: - What every stub agent reports

/// The shell that runs each stub-agent script.
///
/// ``AgentProcess`` demands an absolute command, and the scripts carry no
/// execute bit, so the command is the shell and the script is its argument.
let stubAgentShellCommand = "/bin/sh"

/// The name each stub agent reports in its `initialize` answer.
let stubAgentName = "stub-agent"

/// The version each stub agent reports in its `initialize` answer.
let stubAgentVersion = "1.0.0"

/// The session id each stub agent gives out from `session/new`.
let stubAgentSessionID = SessionId(rawValue: "stub-session")

/// The protocol version ``makeWrongProtocolVersionAgent(pidFile:)`` answers
/// `initialize` with.
///
/// `ProtocolVersion` is a bare integer on the wire, never a string, and 1 is the
/// version of the ACP draft that came before the one this client speaks. So this
/// is the "a v1 agent" half of the fifth row of the check table of
/// `cli-plan.md` §10, written as the number that reaches the wire.
let stubAgentUnsupportedProtocolVersion = ProtocolVersion(rawValue: 1)

/// The message id each stub agent stamps on its reply chunks.
let stubAgentMessageID = MessageId(rawValue: "stub-agent-msg-1")

/// How long a stub agent that will not go away stays alive, in seconds.
///
/// The seventh row of the check table of `cli-plan.md` §10 asks whether an agent left
/// anything behind after its stdin closed, and it answers inside a bounded interval. So an
/// agent that is meant to still be there when the row reads must outlast that interval by
/// far, and it is the caller's teardown that ends it rather than the clock. Five minutes is
/// the same figure `AgentProcessTests` already gives a process it means to group-kill.
private let stubAgentLingerSeconds = 300

/// The reply text a stub agent streams when the caller chose none.
let stubAgentDefaultAnswer = "Hello from the stub agent."

/// The non-JSON line ``makeBannerOnStdoutAgent()`` writes to stdout before it
/// says anything on the wire.
///
/// `cli-plan.md` §10 calls a banner on stdout the most common ACP defect: the
/// agent protocol makes "no non-ACP content on stdout" a MUST, and an agent
/// that breaks it fails in a way that looks like a parsing bug in OUR client.
let stubAgentBannerLine = "stub-agent 1.0.0 — ready"

/// The title the permission request of ``makePermissionRequestingAgent(answer:)``
/// carries.
///
/// The request names no structured subject, so this title is what the binary's
/// refusal line quotes back.
let stubAgentPermissionTitle = "Run the stub tool?"

/// The one authentication method a stub agent advertises beside an element
/// this build cannot read.
///
/// It is an `agent` method, for the reason ``stubAgentAuthMethods`` states.
let stubAgentReadableAuthMethod: AuthMethod = .agent(
    AuthMethodAgent(
        methodId: AuthMethodId(rawValue: "stub-oauth"),
        name: "Sign in with the stub"
    )
)

/// The number of elements ``makeUnreadableAuthMethodAgent(pidFile:)`` puts in
/// its `authMethods` array that this build cannot read.
///
/// The sixth row of the check table of `cli-plan.md` §10 reports this count,
/// so the test that drives that agent reads it from here.
let stubAgentUnreadableAuthMethodCount = 1

/// The authentication methods a probe stub agent advertises.
///
/// Both are `agent` methods. An agent may advertise the `terminal` method only
/// when the client enabled terminal authentication, and this client does not:
/// commit 3f30444 pinned that decision.
let stubAgentAuthMethods: [AuthMethod] = [
    stubAgentReadableAuthMethod,
    .agent(
        AuthMethodAgent(
            methodId: AuthMethodId(rawValue: "stub-token"),
            name: "Paste a stub token"
        )
    ),
]

/// The slash commands a probe stub agent reports when it reports any.
let stubAgentCommands: [AvailableCommand] = [
    AvailableCommand(description: "Makes a plan", name: "create_plan"),
    AvailableCommand(description: "Reads the code", name: "research_codebase"),
]

/// How a probe stub agent reports its slash commands.
///
/// The three cases are the three states `cli-plan.md` §6 asks `probe` to tell
/// apart, seen from the agent's side.
enum StubAgentCommandReport {
    /// The agent reports ``stubAgentCommands``.
    case twoCommands

    /// The agent reports a command list, and the list holds no command.
    case emptyList

    /// The agent sends no `available_commands_update` at all.
    case noUpdate

    /// The commands the agent reports, or `nil` for the case that sends no
    /// update at all.
    var reportedCommands: [AvailableCommand]? {
        switch self {
        case .twoCommands:
            stubAgentCommands
        case .emptyList:
            []
        case .noUpdate:
            nil
        }
    }
}

// MARK: - The stub agents

/// Writes a stub agent that answers every request `cli-plan.md` §14 needs.
///
/// It answers `initialize`, it answers `session/new` with
/// ``stubAgentSessionID``, and on `session/prompt` it sends `answer` as an
/// `agent_message_chunk` update and then a `state_update` carrying `idle` with
/// `stopReason`. It writes ndJSON to stdout and nothing else.
///
/// - Parameters:
///   - answer: The reply text to stream during the prompt turn.
///   - stopReason: The stop reason to end the turn with.
///   - pidFile: Where the agent records its own pid before it answers anything,
///     or `nil` to record none.
///   - transcript: Where the agent appends every request line it reads, or
///     `nil` to record none.
///   - argumentsFile: Where the agent writes its own arguments, one per line,
///     before it answers anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeWellBehavedAgent(
    answer: String = stubAgentDefaultAnswer,
    stopReason: StopReason = .endTurn,
    pidFile: String? = nil,
    transcript: String? = nil,
    argumentsFile: String? = nil
) throws -> String {
    try writeAgentScript(
        requestLoop(
            answer: answer,
            stopReason: stopReason,
            pidFile: pidFile,
            transcript: transcript,
            argumentsFile: argumentsFile
        )
    )
}

/// Writes a stub agent that asks for permission in the middle of its turn,
/// waits for the answer, and then finishes the turn.
///
/// The wait is what makes the stub worth having. A run that never answered the
/// request would leave this agent blocked, so the test that drives it proves
/// the binary ANSWERED `session/request_permission` and not merely that it
/// wrote a line about it. `cli-plan.md` §8 gives a default run no stderr until
/// it fails, and that refusal line is the one deliberate exception the headless
/// decline policy creates.
///
/// - Parameter answer: The reply text to stream once the permission request is
///   answered.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makePermissionRequestingAgent(
    answer: String = stubAgentDefaultAnswer
) throws -> String {
    try writeAgentScript(
        requestLoop(
            answer: answer,
            stopReason: .endTurn,
            pidFile: nil,
            transcript: nil,
            argumentsFile: nil,
            asksPermission: true
        )
    )
}

/// Writes a stub agent that ends its turn with an `idle` carrying no stop
/// reason at all.
///
/// `IdleStateUpdate.stopReason` is optional, and the schema says "Omitted or
/// `null` both mean the agent is not reporting a stop reason". An agent that
/// went idle without saying why still went idle, so this is a completed turn,
/// and `cli-plan.md` §9 gives it the same row as `end_turn`. Nothing but a real
/// agent that omits the member can prove a client reads it that way, which is
/// what this stub is.
///
/// - Parameters:
///   - answer: The reply text to stream during the prompt turn.
///   - pidFile: Where the agent records its own pid before it answers anything,
///     or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeIdleWithoutStopReasonAgent(
    answer: String = stubAgentDefaultAnswer,
    pidFile: String? = nil
) throws -> String {
    try writeAgentScript(
        requestLoop(answer: answer, stopReason: nil, pidFile: pidFile, transcript: nil)
    )
}

/// Writes a stub agent that puts one non-JSON banner line on stdout before its
/// first ndJSON message, and behaves as
/// ``makeWellBehavedAgent(answer:stopReason:pidFile:transcript:argumentsFile:)``
/// after that.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeBannerOnStdoutAgent(pidFile: String? = nil) throws -> String {
    try writeAgentScript(
        """
        \(printfLine(stubAgentBannerLine))
        \(requestLoop(
            answer: stubAgentDefaultAnswer,
            stopReason: .endTurn,
            pidFile: pidFile,
            transcript: nil
        ))
        """
    )
}

/// Writes a stub agent that starts, reads its stdin, and never answers
/// `initialize`.
///
/// The `doctor` timeout check of `cli-plan.md` §10 is what this one is for: it
/// stays alive and silent until its stdin closes, so a client that waits
/// forever hangs and a client that bounds its wait reports a timeout.
///
/// - Parameter pidFile: Where the agent records its own pid before it reads
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: The write failure of the script file.
func makeSilentAgent(pidFile: String? = nil) throws -> String {
    try writeAgentScript(
        """
        \(recordPidStatement(writingTo: pidFile))
        while IFS= read -r line; do
          :
        done
        """
    )
}

/// Writes a stub agent that answers `initialize` the way `initialize` says, and
/// behaves as
/// ``makeWellBehavedAgent(answer:stopReason:pidFile:transcript:argumentsFile:)``
/// after that.
///
/// The agents of this file that differ in their `initialize` answer alone share
/// this one script, so each of them names its answer here and writes no request
/// loop of its own.
///
/// - Parameters:
///   - pidFile: Where the agent records its own pid before it answers anything,
///     or `nil` to record none.
///   - initialize: How the agent answers `initialize`.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
private func makeAgent(
    pidFile: String?,
    initialize: StubAgentInitializeAnswer
) throws -> String {
    try writeAgentScript(
        requestLoop(
            answer: stubAgentDefaultAnswer,
            stopReason: .endTurn,
            pidFile: pidFile,
            initialize: initialize
        )
    )
}

/// Writes a stub agent that answers `initialize` with a protocol version other
/// than the one it was sent.
///
/// The fifth row of the check table of `cli-plan.md` §10 is what this one is
/// for. `ClientSideConnection.initialize(_:)` compares the answered version with
/// the sent one and throws `ProtocolVersionMismatchError` naming both, so only a
/// real agent that answers with ``stubAgentUnsupportedProtocolVersion`` can
/// prove the doctor turns that throw into a row of its own.
///
/// The agent stays alive until its stdin closes, exactly as
/// ``makeInitializeRefusingAgent(pidFile:)`` does, so the reap is the caller's
/// work and never the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeWrongProtocolVersionAgent(pidFile: String? = nil) throws -> String {
    try makeAgent(
        pidFile: pidFile,
        initialize: .reportsProtocolVersion(stubAgentUnsupportedProtocolVersion)
    )
}

/// The status ``makeExitingAtOnceAgent()`` ends with.
///
/// A shell reports 127 for a command it could not find, which is the mistake
/// the second row of the check table of `cli-plan.md` §10 names: the agent's
/// own runtime is missing, so the wrapper dies before it says anything on the
/// wire.
private let commandNotFoundStatus = 127

/// Writes a stub agent that ends the moment it starts.
///
/// The second row of the check table of `cli-plan.md` §10 — "the process
/// starts, and it does not exit at once" — is what this one is for. It writes
/// nothing to stdout and returns, so the client's read of that stdout reaches
/// EOF at once and ``AgentProcess`` reaps the child on its own.
///
/// - Parameter pidFile: Where the agent records its own pid before it ends, or
///   `nil` to record none. The pid is written FIRST, so a caller reading the
///   file afterwards learns the pid of an agent that is already gone.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: The write failure of the script file.
func makeExitingAtOnceAgent(pidFile: String? = nil) throws -> String {
    try writeAgentScript(
        """
        \(recordPidStatement(writingTo: pidFile))
        exit \(commandNotFoundStatus)
        """
    )
}

/// Writes a stub agent that `acp-client probe` can read a whole report off.
///
/// It answers `initialize` with ``stubAgentAuthMethods``, it answers
/// `session/new`, it reports its slash commands the way `commands` says, and it
/// answers `session/close`. It sends nothing a prompt would produce, because
/// `probe` sends no prompt.
///
/// The command list goes out right after the `session/new` answer, which is
/// where a real agent sends it and which is also the moment that proves `probe`
/// reads the list off the observable container: the connection drops an update
/// for a session with no subscriber yet, and the container has no such gate.
///
/// - Parameters:
///   - commands: How the agent reports its slash commands.
///   - transcript: Where the agent appends every request line it reads, or
///     `nil` to record none.
///   - pidFile: Where the agent records its own pid before it answers anything,
///     or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeProbeAgent(
    commands: StubAgentCommandReport = .twoCommands,
    transcript: String? = nil,
    pidFile: String? = nil
) throws -> String {
    try writeAgentScript(
        requestLoop(
            answer: stubAgentDefaultAnswer,
            stopReason: .endTurn,
            pidFile: pidFile,
            transcript: transcript,
            initialize: .reports(stubAgentAuthMethods),
            availableCommands: commands.reportedCommands
        )
    )
}

/// Writes a stub agent that answers `initialize` with a JSON-RPC error.
///
/// `cli-plan.md` §9 gives a protocol failure exit code 1, and §11 lets no agent
/// outlive the command whichever way the command ended. An agent that refuses
/// the handshake reaches both rows, and it stays alive until its stdin closes,
/// so the reap is the binary's work and never the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeInitializeRefusingAgent(pidFile: String? = nil) throws -> String {
    try makeAgent(pidFile: pidFile, initialize: .fails)
}

/// Writes a stub agent that answers `initialize` and then refuses `session/new`
/// with a JSON-RPC error.
///
/// It is the protocol failure that lands AFTER the spawn and BEFORE the turn,
/// which is the one place a leak would be easiest to write: the agent is
/// running, and the command is on its way out through a throw rather than
/// through its own return. `cli-plan.md` §9 gives that run the code 1 and §11
/// still lets no agent outlive it.
///
/// `run` and `probe` both reach this row, because both open a session and only
/// `run` goes on to prompt. The agent stays alive until its stdin closes, so
/// the reap is the binary's work and never the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeNewSessionRefusingAgent(pidFile: String? = nil) throws -> String {
    try writeAgentScript(
        requestLoop(
            answer: stubAgentDefaultAnswer,
            stopReason: .endTurn,
            pidFile: pidFile,
            newSession: .refuses
        )
    )
}

/// Writes a stub agent that answers every request of a probe and then reports
/// `methodNotFound` for `session/close`.
///
/// `session/close` is optional on the wire, so this agent is CONFORMANT rather
/// than broken, and `probe` therefore still writes its report and exits 0.
/// `AgentSession.closeSession(_:)` reports the refusal as one event line and
/// raises nothing — which is exactly the path a leak could hide on, because a
/// teardown that gave up at the refused call would leave the agent running.
///
/// The agent reports ``stubAgentCommands``, so the probe's bounded wait for a
/// command list ends on the list rather than on the clock.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeSessionCloseRefusingAgent(pidFile: String? = nil) throws -> String {
    try writeAgentScript(
        requestLoop(
            answer: stubAgentDefaultAnswer,
            stopReason: .endTurn,
            pidFile: pidFile,
            initialize: .reports(stubAgentAuthMethods),
            closeSession: .refuses,
            availableCommands: stubAgentCommands
        )
    )
}

/// Writes a stub agent whose `initialize` answer leaves `protocolVersion` out.
///
/// The sixth row of the check table of `cli-plan.md` §10 is what this one is for.
/// `InitializeResponse.init(from:)` reads `protocolVersion` with `try container.decode`,
/// so a missing member is a decoding failure rather than a value that degrades to a
/// default. Only `info` and `protocolVersion` behave that way in that answer, so this agent
/// is the shape that proves the row reports an `error` for an answer this build cannot read
/// at all.
///
/// The agent stays alive until its stdin closes, so the reap is the caller's work and never
/// the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeMissingProtocolVersionAgent(pidFile: String? = nil) throws -> String {
    try makeAgent(pidFile: pidFile, initialize: .omitsProtocolVersion)
}

/// Writes a stub agent that answers `initialize` with a `capabilities` object this build
/// cannot read.
///
/// The sixth row of the check table of `cli-plan.md` §10 is what this one is for, and it is
/// the half of that row a stricter decode could never reach. `AgentCapabilities` reads each
/// of its own members with `forgivingDecodeIfPresent`, so a `session` member that is not the
/// object the schema states becomes `nil` and nothing throws. The client then believes the
/// agent supports no `session/*` method at all, which is a silent misreading of a live
/// agent. Only a real agent that sends this shape can prove the row catches it.
///
/// The agent stays alive until its stdin closes, so the reap is the caller's work and never
/// the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeUnreadableCapabilitiesAgent(pidFile: String? = nil) throws -> String {
    try makeAgent(pidFile: pidFile, initialize: .reportsUnreadableCapabilities)
}

/// Writes a stub agent that answers `initialize` with a `capabilities` member
/// that is a string rather than an object.
///
/// The sixth row of the check table of `cli-plan.md` §10 is what this one is
/// for. `InitializeResponse` reads `capabilities` with `forgivingDecode`, which
/// degrades a value that is not an object to the empty default and throws
/// nothing. The client then believes the agent supports no capability at all,
/// and a row that compared the members of an object would have no object to
/// read. Only a real agent that sends this shape can prove the row names the
/// member instead, as it names an `authMethods` member that is not an array.
///
/// The agent stays alive until its stdin closes, so the reap is the caller's
/// work and never the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeNonObjectCapabilitiesAgent(pidFile: String? = nil) throws -> String {
    try makeAgent(pidFile: pidFile, initialize: .reportsNonObjectCapabilities)
}

/// Writes a stub agent that answers `initialize` with a `capabilities` member
/// set to `null`.
///
/// The schema lets the member be absent, and `null` is how an agent that
/// writes every member spells absent. The decode reads it as no member, and
/// the sixth row of the check table of `cli-plan.md` §10 must read it the same
/// way rather than as a member of the wrong shape, as it does for an
/// `authMethods` member set to `null`. Only a real agent that sends `null` can
/// prove the row tells the two apart.
///
/// The agent stays alive until its stdin closes, so the reap is the caller's
/// work and never the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeNullCapabilitiesAgent(pidFile: String? = nil) throws -> String {
    try makeAgent(pidFile: pidFile, initialize: .reportsNullCapabilities)
}

/// Writes a stub agent that answers `initialize` with an `authMethods` array
/// that holds one method this build can read beside one element it cannot.
///
/// The sixth row of the check table of `cli-plan.md` §10 is what this one is
/// for. `InitializeResponse` reads `authMethods` with
/// `forgivingDecodeArrayIfPresent`, which drops each element it cannot read and
/// keeps the rest. The client then sees one method where the agent advertised
/// two, and a person who tries the other one is told it does not exist. Only a
/// real agent that sends this shape can prove the row counts what was dropped.
///
/// The agent stays alive until its stdin closes, so the reap is the caller's
/// work and never the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeUnreadableAuthMethodAgent(pidFile: String? = nil) throws -> String {
    try makeAgent(pidFile: pidFile, initialize: .reportsUnreadableAuthMethod)
}

/// Writes a stub agent that answers `initialize` with an `authMethods` member
/// that is a string rather than an array.
///
/// The sixth row of the check table of `cli-plan.md` §10 is what this one is
/// for. `InitializeResponse` reads `authMethods` with
/// `forgivingDecodeArrayIfPresent`, which degrades a value that is not an array
/// to `nil` and throws nothing. The client then believes the agent advertised
/// no authentication method at all, and a row that counted array elements alone
/// would have nothing to count. Only a real agent that sends this shape can
/// prove the row names the member instead.
///
/// The agent stays alive until its stdin closes, so the reap is the caller's
/// work and never the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeNonArrayAuthMethodsAgent(pidFile: String? = nil) throws -> String {
    try makeAgent(pidFile: pidFile, initialize: .reportsNonArrayAuthMethods)
}

/// Writes a stub agent that answers `initialize` with an `authMethods` member
/// set to `null`.
///
/// The schema lets the member be absent, and `null` is how an agent that
/// writes every member spells absent. The decode reads it as no member, and
/// the sixth row of the check table of `cli-plan.md` §10 must read it the same
/// way rather than as a member of the wrong shape. Only a real agent that
/// sends `null` can prove the row tells the two apart.
///
/// The agent stays alive until its stdin closes, so the reap is the caller's
/// work and never the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeNullAuthMethodsAgent(pidFile: String? = nil) throws -> String {
    try makeAgent(pidFile: pidFile, initialize: .reportsNullAuthMethods)
}

/// Writes a stub agent that answers `initialize` with a `capabilities` object
/// this build cannot read, beside an `authMethods` member that is a string
/// rather than an array.
///
/// The sixth row of the check table of `cli-plan.md` §10 collects one loss for
/// each kind it can find and names them all on one row. An agent that sends
/// both shapes at once is what proves the `authMethods` arm stands BESIDE the
/// `capabilities` arm rather than in its place.
///
/// The agent stays alive until its stdin closes, so the reap is the caller's
/// work and never the agent's own exit.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeUnreadableCapabilitiesAndNonArrayAuthMethodsAgent(
    pidFile: String? = nil
) throws -> String {
    try makeAgent(
        pidFile: pidFile,
        initialize: .reportsUnreadableCapabilitiesAndNonArrayAuthMethods
    )
}

/// Writes a stub agent that streams one answer chunk and then never sends a
/// `state_update` at all.
///
/// The `--timeout` rows of `cli-plan.md` §6.1 and §9 are what this one is for.
/// The turn of §8 ends on `idle` and on nothing else, so an agent that never
/// sends one leaves the run with no ending of its own: a client that bounds the
/// turn ends it at the limit and exits 124, and a client that does not waits
/// for ever.
///
/// The chunk goes out BEFORE the wait, so the run has answer bytes on its
/// standard output by the time the limit lands. That is the half of §8 a
/// timeout must not break: the text that already arrived stays written.
///
/// The agent reports no stop reason, because it sends no `state_update` for one
/// to stand on. It stays alive until its stdin closes, so the reap is the
/// caller's work and never the agent's own exit.
///
/// - Parameters:
///   - answer: The reply text to stream before the turn stops going anywhere.
///   - pidFile: Where the agent records its own pid before it answers anything,
///     or `nil` to record none.
///   - transcript: Where the agent appends every request line it reads, or
///     `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeNeverIdleAgent(
    answer: String = stubAgentDefaultAnswer,
    pidFile: String? = nil,
    transcript: String? = nil
) throws -> String {
    try writeAgentScript(
        requestLoop(
            answer: answer,
            stopReason: nil,
            pidFile: pidFile,
            transcript: transcript,
            turnEnd: .never
        )
    )
}

/// Writes a stub agent that streams one answer chunk, answers the prompt, and
/// then EXITS with no `state_update` at all.
///
/// It is the agent that GOES AWAY in the middle of a turn, and it is what tells
/// the two failures of `cli-plan.md` §9 apart. The turn of §8 ends on `idle`
/// and on nothing else, so this run gets no ending of its own either — but no
/// limit was reached here, and the agent is gone, so the run owes the
/// protocol-failure row AT ONCE. A run that reported the limit instead would
/// both name the wrong failure and wait out a limit nothing reached.
///
/// ``makeNeverIdleAgent(answer:pidFile:)`` is the other half of that pair: it
/// stays alive and says nothing, so its run really does run out of time.
///
/// The chunk goes out BEFORE the exit, so the run has answer bytes on its
/// standard output whichever failure it reports.
///
/// - Parameters:
///   - answer: The reply text to stream before the agent goes away.
///   - pidFile: Where the agent records its own pid before it answers anything,
///     or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeExitingMidTurnAgent(
    answer: String = stubAgentDefaultAnswer,
    pidFile: String? = nil
) throws -> String {
    try writeAgentScript(
        requestLoop(answer: answer, stopReason: nil, pidFile: pidFile, turnEnd: .byExiting)
    )
}

/// Writes a stub agent that streams one answer chunk, waits, and only then ends
/// its turn.
///
/// It is the other half of the `--timeout` rows: a SLOW agent is not a stuck
/// one. A run that gave this agent no limit must wait it out and exit with the
/// code its stop reason owes, and a run whose limit is shorter than the wait
/// must end at the limit instead. One agent serves both readings, so the two
/// tests differ in the option alone.
///
/// - Parameters:
///   - answer: The reply text to stream before the wait.
///   - stopReason: The stop reason to end the turn with.
///   - delaySeconds: How long the agent waits before it sends `idle`. `/bin/sh`
///     hands the wait to `sleep`, which reads whole seconds, so this is an
///     integer.
///   - pidFile: Where the agent records its own pid before it answers anything,
///     or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeSlowTurnAgent(
    answer: String = stubAgentDefaultAnswer,
    stopReason: StopReason = .endTurn,
    delaySeconds: Int,
    pidFile: String? = nil
) throws -> String {
    try writeAgentScript(
        requestLoop(
            answer: answer,
            stopReason: stopReason,
            pidFile: pidFile,
            turnEnd: .afterSeconds(delaySeconds)
        )
    )
}

/// Writes a stub agent that streams one answer chunk, waits for
/// `session/cancel`, and only then ends its turn.
///
/// It is the conformant answer to the first `Ctrl-C` of `cli-plan.md` §11. The
/// schema confirms a cancellation with an `idle` `state_update` carrying
/// `cancelled`, never with the notification returning, so this agent sends
/// nothing until the notification reaches it. A run that never cancelled on
/// the wire therefore never gets an ending at all, and the bound
/// `runAcpClient` puts on a whole run is what ends such a test.
///
/// The chunk goes out BEFORE the wait, so the run has answer bytes on its
/// standard output by the time the interrupt lands. That is the half of §11 an
/// interrupt must not break: the text that already arrived stays written.
///
/// - Parameters:
///   - answer: The reply text to stream before the wait.
///   - pidFile: Where the agent records its own pid before it answers
///     anything, or `nil` to record none.
///   - transcript: Where the agent appends every request line it reads, or
///     `nil` to record none. A test reads it to learn that the turn really
///     started before it sends the signal.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeCancelAwareAgent(
    answer: String = stubAgentDefaultAnswer,
    pidFile: String? = nil,
    transcript: String? = nil
) throws -> String {
    try writeAgentScript(
        requestLoop(
            answer: answer,
            stopReason: .cancelled,
            pidFile: pidFile,
            transcript: transcript,
            turnEnd: .afterCancel
        )
    )
}

/// Writes a stub agent that answers every request and then ignores a closed stdin.
///
/// The seventh row of the check table of `cli-plan.md` §10 is what this one is for: it
/// answers `initialize` the way a conformant agent does, so every earlier row passes, and
/// then it stays alive for ``stubAgentLingerSeconds`` after its stdin reaches EOF. That is
/// the leaked agent §11 forbids, and it is the one defect of the table that is a WARNING
/// rather than an error, because such an agent is usable and it leaks.
///
/// - Parameter pidFile: Where the agent records its own pid before it answers
///   anything, or `nil` to record none.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeLingeringAgent(pidFile: String? = nil) throws -> String {
    try writeAgentScript(
        """
        \(try requestLoop(
            answer: stubAgentDefaultAnswer,
            stopReason: .endTurn,
            pidFile: pidFile
        ))
        sleep \(stubAgentLingerSeconds)
        """
    )
}

/// Writes a stub agent that ends when its stdin closes and leaves a child behind.
///
/// The other half of the seventh row of the check table of `cli-plan.md` §10. The agent
/// itself obeys the rule and ends, so a check that read the agent's pid alone would report
/// `ok`; the child it spawned is what still holds the machine. The child also inherits the
/// agent's stdout, so the pipe never reaches EOF and ``AgentProcess`` never reaps the agent
/// on its own — which is why the row reads the process GROUP rather than the pid.
///
/// The file holds ``stubAgentChildLeavingPidCount`` pids, the agent's own first and its
/// child's second, so a test can prove that neither outlived the run.
///
/// - Parameter pidFile: Where the agent records its own pid and its child's, one per line.
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeChildLeavingAgent(pidFile: String) throws -> String {
    try writeAgentScript(
        """
        sleep \(stubAgentLingerSeconds) &
        printf '%s\\n%s\\n' "$$" "$!" > \(shellSingleQuoted(pidFile))
        \(try requestLoop(answer: stubAgentDefaultAnswer, stopReason: .endTurn))
        """
    )
}

/// How many pids ``makeChildLeavingAgent(pidFile:)`` records: its own, and its
/// child's.
///
/// A test reads the count before it reads the pids, because an agent that never
/// spawned its child would record one pid, and a test that only walked the file
/// would then pass while measuring nothing.
let stubAgentChildLeavingPidCount = 2

// MARK: - The script files

/// The text that stands before the unique part of a stub-agent script's name.
private let agentScriptNamePrefix = "acp-stub-agent-"

/// The extension a stub-agent script's name carries.
///
/// The scripts run as an argument of ``stubAgentShellCommand`` and not on their
/// own, so the extension says what the file holds and nothing more.
private let agentScriptNameSuffix = ".sh"

/// Writes one agent script into a fresh temporary file.
///
/// - Parameter content: The script text.
/// - Returns: The absolute path of the script file.
/// - Throws: The write failure of the script file.
func writeAgentScript(_ content: String) throws -> String {
    try writeTemporaryFile(
        Data(content.utf8),
        prefix: agentScriptNamePrefix,
        suffix: agentScriptNameSuffix
    ).path
}

/// The name of the `run` subcommand on the command line (`cli-plan.md` §6).
let runSubcommandName = "run"

/// The name of the `probe` subcommand on the command line (`cli-plan.md` §6).
let probeSubcommandName = "probe"

/// The name of the `doctor` subcommand on the command line (`cli-plan.md` §6).
let doctorSubcommandName = "doctor"

/// The separator that stands before the agent command (`cli-plan.md` §6).
///
/// It is required. With no separator the binary prints the usage to stderr and
/// exits 2, because there is no default agent.
let agentCommandSeparator = "--"

/// Builds the command line of one `acp-client` subcommand against a stub-agent
/// script.
///
/// The three subcommands take the same grammar — the name, the options of
/// `cli-plan.md` §6.1, the `--` separator, and the agent command — so one
/// builder writes all three and no suite grows a copy of its own.
///
/// The scripts carry no execute bit, so the agent command is
/// ``stubAgentShellCommand`` and the script is its first argument, which is also
/// the shape `cli-plan.md` §6 gives an agent that takes arguments of its own.
/// The agent's own arguments stand after the script, because that is where the
/// shell hands them to it.
///
/// - Parameters:
///   - subcommand: The subcommand name, one of ``runSubcommandName``,
///     ``probeSubcommandName`` and ``doctorSubcommandName``.
///   - options: Everything that stands between the name and the separator: the
///     options of `cli-plan.md` §6.1, and the prompt argument of `run`.
///   - script: The absolute path of the stub-agent script.
///   - agentArguments: The agent's own arguments, after the script.
/// - Returns: The arguments for
///   ``runAcpClient(_:standardInput:standardOutput:environment:signals:within:)``.
func agentCommandArguments(
    _ subcommand: String,
    options: [String] = [],
    script: String,
    agentArguments: [String] = []
) -> [String] {
    [subcommand] + options
        + [agentCommandSeparator, stubAgentShellCommand, script] + agentArguments
}

/// Builds the command line of one `acp-client run` against a stub-agent script.
///
/// - Parameters:
///   - prompt: The prompt argument, or `nil` to put none on the line, which is
///     the §7 row that reads the prompt off standard input.
///   - options: The options of `cli-plan.md` §6.1 to put before the separator.
///   - script: The absolute path of the stub-agent script.
///   - agentArguments: The agent's own arguments, after the script.
/// - Returns: The arguments for
///   ``runAcpClient(_:standardInput:standardOutput:environment:signals:within:)``.
func runArguments(
    prompt: String?,
    options: [String] = [],
    script: String,
    agentArguments: [String] = []
) -> [String] {
    agentCommandArguments(
        runSubcommandName,
        options: (prompt.map { [$0] } ?? []) + options,
        script: script,
        agentArguments: agentArguments
    )
}

/// The permission bits an agent command needs to reach `posix_spawn` at all.
///
/// ``AgentCommandResolver`` refuses a file that carries no executable bit, so a
/// file that means to fail at the SPAWN has to pass that check first.
private let executablePermissions: NSNumber = 0o755

/// The bytes ``makeUnexecutableAgentBinary()`` writes.
///
/// They are not a Mach-O header and not a `#!` line, which is what makes
/// `posix_spawn` answer `ENOEXEC`.
private let unexecutableAgentContent = "this is not an executable format\n"

/// Writes a file that resolves as an agent command and that cannot be executed.
///
/// It is the one shape that reaches ``AgentProcessError/spawnFailed(command:errno:)``
/// from the command line. ``AgentCommandResolver`` asks three questions — the
/// file exists, it is a regular file, and it carries the executable bit — and
/// this file answers yes to all three, so the failure lands at the spawn and
/// never at the resolution. `posix_spawn` then answers `ENOEXEC`, and no child
/// is made at all.
///
/// - Returns: The absolute path of the file; the caller removes it with
///   ``removeAgentScript(_:)``.
/// - Throws: The write failure of the file, or the failure of the permission
///   change.
func makeUnexecutableAgentBinary() throws -> String {
    let path = try writeAgentScript(unexecutableAgentContent)
    try FileManager.default.setAttributes(
        [.posixPermissions: executablePermissions],
        ofItemAtPath: path
    )
    return path
}

/// Removes a script a builder in this file wrote.
///
/// The removal is best effort: the script has already done its work by the time
/// a test tears down, and a temporary file that outlives one run is not a
/// reason to fail a test that otherwise passed.
///
/// - Parameter path: The absolute path a builder returned.
func removeAgentScript(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

/// Reads every pid a stub agent recorded, in the order the agent wrote them.
///
/// Most stub agents record one pid, their own.
/// ``makeChildLeavingAgent(pidFile:)`` records two — its own and its child's —
/// because `cli-plan.md` §11 asks the same question of both, and one file keeps
/// the two answers together.
///
/// - Parameter file: The pid file the agent wrote.
/// - Returns: The pids the file holds.
/// - Throws: The read failure of the file, or a requirement failure when a line
///   of the file is not a pid.
func recordedAgentPids(in file: URL) throws -> [pid_t] {
    try String(contentsOf: file, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { line in
            let recorded = line.trimmingCharacters(in: .whitespaces)
            return try #require(pid_t(recorded), "the pid file held \"\(recorded)\"")
        }
}

/// Reads the pid a stub agent recorded through ``recordPidStatement(writingTo:)``.
///
/// It is the one reader every suite here shares, because every suite asks the
/// same question of it: `cli-plan.md` §11 lets no agent outlive the command,
/// and a pid read back from a file is what ``processExists(_:)`` probes.
///
/// - Parameter file: The pid file the agent wrote.
/// - Returns: The pid.
/// - Throws: The read failure of the file, or a requirement failure when the
///   file holds no pid.
func recordedAgentPid(in file: URL) throws -> pid_t {
    try #require(recordedAgentPids(in: file).first, "the pid file at \(file.path) holds no pid")
}

/// Answers whether a stub agent has already read a request naming `method`.
///
/// The transcript is where a stub agent appends every request line it reads,
/// and a line naming a method is the only evidence from OUTSIDE the run that
/// the run reached that method. A test that interrupts a LIVE turn reads it to
/// learn that the turn really started: `cli-plan.md` §11 is about a `Ctrl-C`
/// in the middle of a turn, and a signal that landed before the prompt went
/// out would measure something else.
///
/// - Parameters:
///   - file: The transcript file the agent appends to.
///   - method: The wire method name to look for.
/// - Returns: `true` when the agent has already read such a request. A
///   transcript the agent has not created yet answers `false`.
func transcriptHolds(_ file: URL, method: String) -> Bool {
    guard let transcript = try? String(contentsOf: file, encoding: .utf8) else { return false }
    return transcript.contains("\"method\":\"\(method)\"")
}

// MARK: - The script text

/// The `jsonrpc` value every ACP message carries.
private let jsonRPCVersion = "2.0"

/// The id the stub answers `initialize` with.
///
/// A client sends its requests in a known order — `initialize`, then
/// `session/new`, then `session/prompt` — so the three answers can carry the
/// fixed ids 1, 2 and 3 rather than reading the id out of the request. A shell
/// script has no JSON parser to read it with.
private let initializeAnswerID = 1

/// The id the stub answers `session/new` with. See ``initializeAnswerID``.
private let newSessionAnswerID = 2

/// The id the stub answers `session/prompt` with. See ``initializeAnswerID``.
private let promptAnswerID = 3

/// The id the stub stamps on its own `session/request_permission` request.
///
/// It stands well clear of the three answer ids above so a reader can tell the
/// one message the AGENT originates from the three it answers. The two
/// directions carry independent id spaces on the wire, so the distance buys
/// legibility rather than correctness.
private let permissionRequestID = 100

/// Builds the request loop that every answering stub agent shares.
///
/// The loop reads one ndJSON line at a time and matches the method name as
/// plain text, which is all a shell can do and all this stub needs.
///
/// - Parameters:
///   - answer: The reply text to stream during the prompt turn.
///   - stopReason: The stop reason to end the turn with, or `nil` for an `idle`
///     that reports no stop reason at all.
///   - pidFile: Where the agent records its own pid before it answers anything,
///     or `nil` to record none.
///   - transcript: Where the agent appends every request line it reads, or
///     `nil` to record none.
///   - argumentsFile: Where the agent writes its own arguments, one per line,
///     before it answers anything, or `nil` to record none.
///   - asksPermission: Whether the agent asks for permission in the middle of
///     the turn, and waits for the answer before it finishes.
///   - initialize: How the agent answers `initialize`.
///   - newSession: How the agent answers `session/new`.
///   - closeSession: How the agent answers `session/close`.
///   - availableCommands: The slash commands the agent reports right after its
///     `session/new` answer, or `nil` to send no `available_commands_update`.
///   - turnEnd: What the agent does once it has streamed its answer chunk. The
///     default sends the `idle` update at once, which is what a conformant
///     agent with nothing left to do does.
/// - Returns: The script text.
/// - Throws: A JSON-encoding failure.
private func requestLoop(
    answer: String,
    stopReason: StopReason?,
    pidFile: String? = nil,
    transcript: String? = nil,
    argumentsFile: String? = nil,
    asksPermission: Bool = false,
    initialize: StubAgentInitializeAnswer = .reports([]),
    newSession: StubAgentRequestAnswer = .answers,
    closeSession: StubAgentRequestAnswer = .answers,
    availableCommands: [AvailableCommand]? = nil,
    turnEnd: StubAgentTurnEnd = .atOnce
) throws -> String {
    """
    \(recordPidStatement(writingTo: pidFile))
    \(recordArgumentsStatement(writingTo: argumentsFile))
    while IFS= read -r line; do
      \(recordRequestStatement(appendingTo: transcript))
      case "$line" in
        *'"method":"initialize"'*)
          \(try printfLine(initializeAnswer(initialize)))
          ;;
        *'"method":"session/new"'*)
          \(try printfLine(newSessionAnswer(newSession)))
          \(try commandUpdateStatement(reporting: availableCommands))
          ;;
        *'"method":"session/close"'*)
          \(try printfLine(closeSessionAnswer(closeSession)))
          ;;
        *'"method":"session/prompt"'*)
          \(try printfLine(promptAnswer()))
          \(try permissionExchangeStatements(asking: asksPermission))
          \(try printfLine(messageChunk(answer)))
          \(try turnEndStatements(turnEnd, stopReason: stopReason))
          ;;
      esac
    done
    """
}

/// Renders the shell statement that reports the agent's slash commands.
///
/// The statement stands inside the `session/new` arm, so the update follows the
/// answer that named the session it belongs to.
///
/// - Parameter commands: The commands to report, or `nil` to report none at
///   all. An EMPTY array is not `nil`: it reports a command list that holds no
///   command, which `cli-plan.md` §6 keeps apart from an agent that never
///   reported one.
/// - Returns: One shell statement, or the empty string.
/// - Throws: A JSON-encoding failure.
private func commandUpdateStatement(reporting commands: [AvailableCommand]?) throws -> String {
    guard let commands else { return "" }
    return printfLine(try availableCommandsUpdate(commands))
}

/// Renders the shell statement that records the agent's own pid.
///
/// `$$` is the pid of the shell running the script, and that shell is what
/// ``AgentProcess`` spawned, so a test that reads the file afterwards learns
/// the pid to probe. `cli-plan.md` §11 lets no agent outlive the run, and a pid
/// read back from a file is the only way to check that from outside the run.
///
/// - Parameter path: Where to write the pid, or `nil` to write none.
/// - Returns: One shell statement, or the empty string.
private func recordPidStatement(writingTo path: String?) -> String {
    guard let path else { return "" }
    return "printf '%s\\n' \"$$\" > \(shellSingleQuoted(path))"
}

/// Renders the shell statement that appends the request line just read to a
/// transcript file.
///
/// A `/bin/sh` agent has no JSON parser, so it cannot answer WITH what it was
/// sent. Writing each raw request line to a file is what lets a test assert
/// what reached the agent — the prompt text among it.
///
/// - Parameter path: Where to append each request line, or `nil` to record
///   none.
/// - Returns: One shell statement, or the empty string.
private func recordRequestStatement(appendingTo path: String?) -> String {
    guard let path else { return "" }
    return "printf '%s\\n' \"$line\" >> \(shellSingleQuoted(path))"
}

/// Renders the shell statement that records the agent's own arguments, one per
/// line.
///
/// `"$@"` holds the arguments that stand AFTER the script path on the
/// ``stubAgentShellCommand`` command line, which is exactly what a caller put
/// after the agent command that follows `--` (`cli-plan.md` §6). A run that
/// gave the agent no argument of its own writes an EMPTY file rather than
/// none, because the redirection stands on the loop and not inside it, so a
/// test can tell "no arguments reached the agent" from "the agent never ran".
///
/// - Parameter path: Where to write the arguments, or `nil` to write none.
/// - Returns: One shell statement, or the empty string.
private func recordArgumentsStatement(writingTo path: String?) -> String {
    guard let path else { return "" }
    return """
        for stubAgentArgument in "$@"; do \
        printf '%s\\n' "$stubAgentArgument"; \
        done > \(shellSingleQuoted(path))
        """
}

/// Renders the shell statements that ask for permission mid-turn and wait for
/// the answer.
///
/// The wait is a read loop rather than a single `read`, because the client may
/// send other messages before its answer. It ends on the line carrying this
/// request's id, which is the answer by JSON-RPC's own correlation rule.
///
/// - Parameter asking: Whether the agent asks at all.
/// - Returns: The shell statements, or the empty string.
/// - Throws: A JSON-encoding failure.
private func permissionExchangeStatements(asking: Bool) throws -> String {
    guard asking else { return "" }
    return """
        \(printfLine(try permissionRequest()))
        \(waitForLineStatements(holding: "\"id\":\(permissionRequestID)", into: "permissionAnswer"))
        """
}

/// The line text a stub agent waits for when it waits for a cancellation.
///
/// It is the `method` member of `session/cancel`, spelled as it stands in the
/// ndJSON the client writes. `MethodTable.generated.swift` of the wire package
/// is where that name is fixed.
private let cancelMethodMarker = "\"method\":\"session/cancel\""

/// Renders the shell statements that wait for `session/cancel` and then end
/// the turn.
///
/// - Parameter stopReason: The stop reason the closing `idle` update carries.
/// - Returns: The shell statements.
/// - Throws: A JSON-encoding failure.
private func cancelWaitStatements(thenReporting stopReason: StopReason?) throws -> String {
    """
    \(waitForLineStatements(holding: cancelMethodMarker, into: "cancelLine"))
    \(printfLine(try idleState(stopReason)))
    """
}

/// Renders the shell statements that read incoming lines until one holds
/// `marker`, and then stop reading.
///
/// The wait is a read loop rather than a single `read`, because the client may
/// send other messages before the one this agent is waiting for.
///
/// - Parameters:
///   - marker: The literal text the awaited line holds.
///   - variable: The shell variable each read line goes into. Two waits in one
///     script take two names, so neither can read the other's last line.
/// - Returns: The shell statements.
private func waitForLineStatements(holding marker: String, into variable: String) -> String {
    """
    while IFS= read -r \(variable); do
      case "$\(variable)" in
        *\(shellSingleQuoted(marker))*) break ;;
      esac
    done
    """
}

/// The `session/request_permission` request this stub sends in the middle of
/// its turn.
///
/// It offers one option of each kind the binary tells apart — an allow and a
/// rejection — and it names no structured subject, so the refusal line the
/// binary writes quotes ``stubAgentPermissionTitle``.
///
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func permissionRequest() throws -> String {
    try ndjsonLine([
        "id": permissionRequestID,
        "jsonrpc": jsonRPCVersion,
        "method": "session/request_permission",
        "params": [
            "options": [
                [
                    "kind": PermissionOptionKind.allowOnce.wireValue,
                    "name": "Allow",
                    "optionId": "allow-once",
                ],
                [
                    "kind": PermissionOptionKind.rejectOnce.wireValue,
                    "name": "Reject",
                    "optionId": "reject-once",
                ],
            ],
            "sessionId": stubAgentSessionID.rawValue,
            "title": stubAgentPermissionTitle,
        ],
    ])
}

/// What a stub agent does once it has streamed its answer chunk.
///
/// The turn of `cli-plan.md` §8 ends on an `idle` `state_update` and on nothing
/// else, so these cases are the endings a client has to tell apart: a turn that
/// ends at once, a turn that is merely slow, a turn that ends only when the
/// client cancels it, and a turn that never ends at all.
private enum StubAgentTurnEnd {
    /// The agent sends the `idle` update at once.
    case atOnce

    /// The agent waits this many whole seconds, and then sends the `idle`
    /// update.
    case afterSeconds(Int)

    /// The agent waits for `session/cancel`, and then sends the `idle` update.
    ///
    /// It is the conformant answer to the first `Ctrl-C` of `cli-plan.md` §11,
    /// and nothing but a cancellation on the wire moves it.
    case afterCancel

    /// The agent sends no `state_update` at all, so the turn has no ending of
    /// its own. The stop reason the caller named reaches the wire nowhere.
    case never

    /// The agent EXITS, and sends no `state_update` first.
    ///
    /// It is not the same ending as ``never``: that agent stays alive and says
    /// nothing, while this one goes away. The client sees its incoming bytes
    /// end, so the turn has a definite protocol failure to report at once, and
    /// no limit has been reached.
    case byExiting
}

/// Renders the shell statements that end one stub agent's turn.
///
/// - Parameters:
///   - turnEnd: What the agent does once it has streamed its answer chunk.
///   - stopReason: The stop reason to report, or `nil` to report none. A
///     ``StubAgentTurnEnd/never`` agent sends no update to carry it.
/// - Returns: The shell statements, or the empty string.
/// - Throws: A JSON-encoding failure.
private func turnEndStatements(
    _ turnEnd: StubAgentTurnEnd,
    stopReason: StopReason?
) throws -> String {
    switch turnEnd {
    case .atOnce:
        return printfLine(try idleState(stopReason))
    case .afterSeconds(let seconds):
        return "sleep \(seconds)\n\(printfLine(try idleState(stopReason)))"
    case .afterCancel:
        return try cancelWaitStatements(thenReporting: stopReason)
    case .never:
        return ""
    case .byExiting:
        return "exit \(stubAgentGoingAwayExitStatus)"
    }
}

/// The exit status the agent of ``StubAgentTurnEnd/byExiting`` ends with.
///
/// It ends CLEANLY. The run must fail on the `state_update` that never came,
/// and a non-zero status here would give a client a second reason to fail with,
/// which is one reason too many for a test that names the first.
private let stubAgentGoingAwayExitStatus = 0

/// How a stub agent answers `initialize`.
private enum StubAgentInitializeAnswer {
    /// The agent answers with the protocol version it was sent, its
    /// capabilities, and these authentication methods. An empty list advertises
    /// none.
    case reports([AuthMethod])

    /// The agent answers with this protocol version rather than the one it was
    /// sent, and advertises no authentication method.
    case reportsProtocolVersion(ProtocolVersion)

    /// The agent leaves `protocolVersion` out of its answer altogether.
    case omitsProtocolVersion

    /// The agent answers with a `capabilities` object holding a member this build
    /// cannot read.
    case reportsUnreadableCapabilities

    /// The agent answers with a `capabilities` member that is a string rather
    /// than an object.
    case reportsNonObjectCapabilities

    /// The agent answers with a `capabilities` member set to `null`.
    case reportsNullCapabilities

    /// The agent answers with an `authMethods` array that holds
    /// ``stubAgentReadableAuthMethod`` beside
    /// ``stubAgentUnreadableAuthMethodCount`` elements this build cannot read.
    case reportsUnreadableAuthMethod

    /// The agent answers with an `authMethods` member that is a string rather
    /// than an array.
    case reportsNonArrayAuthMethods

    /// The agent answers with an `authMethods` member set to `null`.
    case reportsNullAuthMethods

    /// The agent answers with a `capabilities` object holding a member this
    /// build cannot read, beside an `authMethods` member that is a string
    /// rather than an array.
    case reportsUnreadableCapabilitiesAndNonArrayAuthMethods

    /// The agent answers with a JSON-RPC error, and the handshake fails.
    case fails
}

/// The `capabilities` member a conformant stub agent answers `initialize` with.
///
/// `{"session": {}}` is what the schema calls the baseline session surface: the agent
/// serves `session/new`, `session/prompt`, `session/cancel` and `session/update`.
///
/// - Returns: The member, as the untyped JSON `JSONSerialization` writes.
private func readableStubAgentCapabilities() -> [String: Any] {
    ["session": [String: String]()]
}

/// The `capabilities` member ``makeUnreadableCapabilitiesAgent(pidFile:)`` answers
/// `initialize` with.
///
/// The schema states `session` as an object, and this sends a string in its place.
/// `AgentCapabilities` reads that member with `forgivingDecodeIfPresent`, so the decode
/// gives `nil` and throws nothing at all: the client silently believes the agent serves no
/// `session/*` method. That silence is the defect the sixth row of the check table of
/// `cli-plan.md` §10 exists to catch.
///
/// - Returns: The member, as the untyped JSON `JSONSerialization` writes.
private func unreadableStubAgentCapabilities() -> [String: Any] {
    ["session": "yes"]
}

/// The `capabilities` member ``makeNonObjectCapabilitiesAgent(pidFile:)``
/// answers `initialize` with.
///
/// The schema states `capabilities` as an object, and this sends a bare
/// capability name in its place, which is the shape an agent that named its
/// surface rather than describing it writes. `InitializeResponse` reads the
/// member with `forgivingDecode`, so the decode gives the empty default and
/// throws nothing at all: the client silently believes the agent supports no
/// capability. That silence is what the sixth row of the check table of
/// `cli-plan.md` §10 reports.
private let nonObjectStubAgentCapabilities = "session"

/// One element of the `authMethods` array
/// ``makeUnreadableAuthMethodAgent(pidFile:)`` answers `initialize` with, and
/// this build cannot read.
///
/// The `type` member says `agent`, and the schema states `methodId` and `name`
/// for that shape. This element carries `id` in place of `methodId`, so
/// `AuthMethodAgent(from:)` throws. `InitializeResponse` reads the array with
/// `forgivingDecodeArrayIfPresent`, which drops the element and throws nothing:
/// the client silently believes the agent advertised one method fewer. That
/// silence is what the sixth row of the check table of `cli-plan.md` §10
/// reports.
///
/// - Returns: The element, as the untyped JSON `JSONSerialization` writes.
private func unreadableStubAgentAuthMethod() -> [String: Any] {
    ["type": "agent", "id": "stub-broken", "name": "Sign in with the broken stub"]
}

/// The `authMethods` member ``makeNonArrayAuthMethodsAgent(pidFile:)`` answers
/// `initialize` with.
///
/// The schema states `authMethods` as an array, and this sends a bare method
/// id in its place, which is the shape an agent that forgot the brackets
/// writes. `InitializeResponse` reads the member with
/// `forgivingDecodeArrayIfPresent`, so the decode gives `nil` and throws
/// nothing at all: the client silently believes the agent advertised no
/// method. That silence is what the sixth row of the check table of
/// `cli-plan.md` §10 reports.
private let nonArrayStubAgentAuthMethods = "stub-oauth"

/// The JSON-RPC code an agent answers with when it will not serve a request it
/// understood.
///
/// It is the spec's `Internal error`, which is what an agent that cannot
/// initialize reports. The number is spelled here because JSON-RPC fixes it and
/// no Swift type in this package names it.
private let jsonRPCInternalErrorCode = -32_603

/// The JSON-RPC code an agent answers with when it does not implement a method
/// at all.
///
/// It is the spec's `Method not found`. `session/close` is optional on the
/// wire, and `AgentSession.closeSession(_:)` reads exactly this code as "that
/// agent gave the call no answer of its own", so it is the code a stub that
/// does not implement the method has to send.
private let jsonRPCMethodNotFoundCode = -32_601

/// The message a refusing stub agent puts in its `initialize` error.
private let stubAgentInitializeRefusal = "the stub agent refuses to initialize"

/// The message a refusing stub agent puts in its `session/new` error.
private let stubAgentNewSessionRefusal = "the stub agent refuses to open a session"

/// The message a stub agent that does not implement `session/close` answers
/// with.
private let stubAgentCloseSessionRefusal = "the stub agent has no session/close"

/// How a stub agent answers one request of the handshake.
///
/// The two cases are the two things an agent can do with a request that reached
/// it: answer it, or refuse it. `cli-plan.md` §9 gives a refusal the
/// protocol-failure row, and §11 asks the same reap of that row as of every
/// other row, so a refusal is a whole exit path of its own.
private enum StubAgentRequestAnswer {
    /// The agent answers the request.
    case answers

    /// The agent answers with a JSON-RPC error.
    case refuses
}

/// The `initialize` answer the caller asked for.
///
/// - Parameter answer: How the agent answers.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func initializeAnswer(_ answer: StubAgentInitializeAnswer) throws -> String {
    switch answer {
    case .reports(let authMethods):
        try initializeResult(
            reporting: authMethods,
            protocolVersion: ACPClient.supportedProtocolVersion
        )
    case .reportsProtocolVersion(let protocolVersion):
        try initializeResult(reporting: [], protocolVersion: protocolVersion)
    case .omitsProtocolVersion:
        try initializeResult(reporting: [], protocolVersion: nil)
    case .reportsUnreadableCapabilities:
        try initializeResult(
            reporting: [],
            protocolVersion: ACPClient.supportedProtocolVersion,
            capabilities: unreadableStubAgentCapabilities()
        )
    case .reportsNonObjectCapabilities:
        try initializeResult(
            authMethodsMember: nil,
            protocolVersion: ACPClient.supportedProtocolVersion,
            capabilitiesMember: nonObjectStubAgentCapabilities
        )
    case .reportsNullCapabilities:
        try initializeResult(
            authMethodsMember: nil,
            protocolVersion: ACPClient.supportedProtocolVersion,
            capabilitiesMember: NSNull()
        )
    case .reportsUnreadableAuthMethod:
        try initializeResult(
            reporting: [stubAgentReadableAuthMethod],
            protocolVersion: ACPClient.supportedProtocolVersion,
            unreadableAuthMethods: Array(
                repeating: unreadableStubAgentAuthMethod(),
                count: stubAgentUnreadableAuthMethodCount
            )
        )
    case .reportsNonArrayAuthMethods:
        try initializeResult(
            authMethodsMember: nonArrayStubAgentAuthMethods,
            protocolVersion: ACPClient.supportedProtocolVersion
        )
    case .reportsNullAuthMethods:
        try initializeResult(
            authMethodsMember: NSNull(),
            protocolVersion: ACPClient.supportedProtocolVersion
        )
    case .reportsUnreadableCapabilitiesAndNonArrayAuthMethods:
        try initializeResult(
            authMethodsMember: nonArrayStubAgentAuthMethods,
            protocolVersion: ACPClient.supportedProtocolVersion,
            capabilitiesMember: unreadableStubAgentCapabilities()
        )
    case .fails:
        try requestError(
            id: initializeAnswerID,
            code: jsonRPCInternalErrorCode,
            message: stubAgentInitializeRefusal
        )
    }
}

/// The successful `initialize` answer: one protocol version, the stub's own name
/// and version, a session capability, and the authentication methods the caller
/// chose.
///
/// - Parameters:
///   - authMethods: The authentication methods to advertise. An empty list,
///     beside no unreadable element, leaves the member out, which is what an
///     agent that advertises none sends.
///   - protocolVersion: The protocol version to answer with. It reaches the wire
///     as a bare integer, which is the only form `ProtocolVersion` takes. `nil`
///     leaves the member out altogether, which is one of only two ways to make
///     that answer undecodable at all.
///   - capabilities: The `capabilities` member to answer with. The default is the
///     baseline session surface every conformant stub advertises.
///   - unreadableAuthMethods: Elements of the `authMethods` array this build
///     cannot read, as the untyped JSON `JSONSerialization` writes. They stand
///     after the readable methods. The default sends none.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func initializeResult(
    reporting authMethods: [AuthMethod],
    protocolVersion: ProtocolVersion?,
    capabilities: [String: Any] = readableStubAgentCapabilities(),
    unreadableAuthMethods: [Any] = []
) throws -> String {
    let advertised = try authMethods.map { try jsonValue(of: $0) } + unreadableAuthMethods
    return try initializeResult(
        authMethodsMember: advertised.isEmpty ? nil : advertised,
        protocolVersion: protocolVersion,
        capabilitiesMember: capabilities
    )
}

/// The successful `initialize` answer, with its `authMethods` and
/// `capabilities` members written exactly as the caller gave them.
///
/// This is the one place the two members reach the wire, so it is where an
/// agent that sends either one in a shape the schema does not state is
/// scripted. The array-building overload above is what every conformant stub
/// uses.
///
/// - Parameters:
///   - authMethodsMember: The `authMethods` member, as the untyped JSON
///     `JSONSerialization` writes, or `nil` to leave the member out. An
///     `NSNull` writes `null`, and a string writes a string.
///   - protocolVersion: The protocol version to answer with, or `nil` to leave
///     the member out.
///   - capabilitiesMember: The `capabilities` member, as the untyped JSON
///     `JSONSerialization` writes. An `NSNull` writes `null`, and a string
///     writes a string. The default is the baseline session surface every
///     conformant stub advertises.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func initializeResult(
    authMethodsMember: Any?,
    protocolVersion: ProtocolVersion?,
    capabilitiesMember: Any = readableStubAgentCapabilities()
) throws -> String {
    var result: [String: Any] = [
        "capabilities": capabilitiesMember,
        "info": ["name": stubAgentName, "version": stubAgentVersion],
    ]
    if let protocolVersion {
        result["protocolVersion"] = protocolVersion.rawValue
    }
    if let authMethodsMember {
        result["authMethods"] = authMethodsMember
    }
    return try ndjsonLine([
        "id": initializeAnswerID,
        "jsonrpc": jsonRPCVersion,
        "result": result,
    ])
}

/// One JSON-RPC error answer.
///
/// The three refusals this file can script differ in the id they answer, the
/// code they carry and the text they name, and in nothing else, so one builder
/// writes all three.
///
/// - Parameters:
///   - id: The request id this error answers.
///   - code: The JSON-RPC error code to carry.
///   - message: The text to name.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func requestError(id: Int, code: Int, message: String) throws -> String {
    try ndjsonLine([
        "error": ["code": code, "message": message],
        "id": id,
        "jsonrpc": jsonRPCVersion,
    ])
}

/// The `session/close` answer the caller asked for.
///
/// The id is ``promptAnswerID`` because the answers of this stub are numbered by
/// the ORDER the client sends its requests in, and `probe` sends no prompt: its
/// third request is `session/close`. See ``initializeAnswerID``.
///
/// - Parameter answer: How the agent answers.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func closeSessionAnswer(_ answer: StubAgentRequestAnswer) throws -> String {
    switch answer {
    case .answers:
        return try ndjsonLine([
            "id": promptAnswerID,
            "jsonrpc": jsonRPCVersion,
            "result": [String: String](),
        ])
    case .refuses:
        return try requestError(
            id: promptAnswerID,
            code: jsonRPCMethodNotFoundCode,
            message: stubAgentCloseSessionRefusal
        )
    }
}

/// One `available_commands_update` carrying the agent's slash commands.
///
/// - Parameter commands: The commands to report, which may hold none.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func availableCommandsUpdate(_ commands: [AvailableCommand]) throws -> String {
    try sessionUpdate([
        "availableCommands": try jsonValue(of: commands),
        "sessionUpdate": "available_commands_update",
    ])
}

/// Renders one wire value as the untyped JSON `JSONSerialization` writes.
///
/// The stub builds its messages as dictionaries, because a `/bin/sh` script
/// carries them as text. A wire value goes through its own `Codable`
/// conformance first, so the script says exactly what the schema says and no
/// member is spelled again here.
///
/// - Parameter value: The wire value to render.
/// - Returns: The value as arrays, dictionaries and scalars.
/// - Throws: A JSON-encoding failure.
private func jsonValue(of value: some Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value))
}

/// The `session/new` answer the caller asked for: the one session id this stub
/// gives out, or a refusal.
///
/// - Parameter answer: How the agent answers.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func newSessionAnswer(_ answer: StubAgentRequestAnswer) throws -> String {
    switch answer {
    case .answers:
        return try ndjsonLine([
            "id": newSessionAnswerID,
            "jsonrpc": jsonRPCVersion,
            "result": ["sessionId": stubAgentSessionID.rawValue],
        ])
    case .refuses:
        return try requestError(
            id: newSessionAnswerID,
            code: jsonRPCInternalErrorCode,
            message: stubAgentNewSessionRefusal
        )
    }
}

/// The `session/prompt` acknowledgement. The turn's content follows it as
/// notifications.
///
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func promptAnswer() throws -> String {
    try ndjsonLine([
        "id": promptAnswerID,
        "jsonrpc": jsonRPCVersion,
        "result": [String: String](),
    ])
}

/// One `agent_message_chunk` update carrying the reply text.
///
/// - Parameter answer: The reply text.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func messageChunk(_ answer: String) throws -> String {
    try sessionUpdate([
        "content": ["text": answer, "type": "text"],
        "messageId": stubAgentMessageID.rawValue,
        "sessionUpdate": "agent_message_chunk",
    ])
}

/// One `state_update` carrying `idle`, which is what ends the turn, and the
/// stop reason where the caller chose one.
///
/// The member is left OUT for a `nil` stop reason rather than written as
/// `null`. The schema reads the two the same way, and a real agent that reports
/// no reason omits the member, so the omission is the case worth scripting.
///
/// - Parameter stopReason: The stop reason to report, or `nil` to report none.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func idleState(_ stopReason: StopReason?) throws -> String {
    var update: [String: Any] = ["sessionUpdate": "state_update", "state": "idle"]
    if let stopReason {
        update["stopReason"] = stopReason.wireValue
    }
    return try sessionUpdate(update)
}

/// Wraps one update in the `session/update` notification the wire expects.
///
/// - Parameter update: The `update` member of the notification's parameters.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func sessionUpdate(_ update: [String: Any]) throws -> String {
    try ndjsonLine([
        "jsonrpc": jsonRPCVersion,
        "method": "session/update",
        "params": ["sessionId": stubAgentSessionID.rawValue, "update": update],
    ])
}

/// Renders one message as the single ndJSON line a stub agent writes.
///
/// The keys are sorted, so two builds of one message give one text and a
/// reader can compare two scripts by eye.
///
/// - Parameter message: The message members.
/// - Returns: The message as one line of JSON, with no newline.
/// - Throws: A JSON-encoding failure.
private func ndjsonLine(_ message: [String: Any]) throws -> String {
    let encoded = try JSONSerialization.data(
        withJSONObject: message,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return String(decoding: encoded, as: UTF8.self)
}

/// Renders the shell statement that writes `line` and a newline to stdout.
///
/// `printf '%s\n'` and not `echo`, because `echo` reads backslash escapes in
/// some shells and a JSON string carries backslashes.
///
/// - Parameter line: The text to write.
/// - Returns: One shell statement.
private func printfLine(_ line: String) -> String {
    "printf '%s\\n' \(shellSingleQuoted(line))"
}

/// Wraps `text` in single quotes for `/bin/sh`.
///
/// A single quote inside the text ends the quoted run, so each one becomes
/// `'\''`: end the run, an escaped quote, start a new run. Nothing else is
/// special inside single quotes, so this is the whole rule.
///
/// - Parameter text: The text to quote.
/// - Returns: The quoted text, quotes included.
private func shellSingleQuoted(_ text: String) -> String {
    "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
}
