import Foundation
import FoundationModelsACP

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

/// The message id each stub agent stamps on its reply chunks.
let stubAgentMessageID = MessageId(rawValue: "stub-agent-msg-1")

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
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func makeBannerOnStdoutAgent() throws -> String {
    try writeAgentScript(
        """
        \(printfLine(stubAgentBannerLine))
        \(requestLoop(
            answer: stubAgentDefaultAnswer,
            stopReason: .endTurn,
            pidFile: nil,
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
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: The write failure of the script file.
func makeSilentAgent() throws -> String {
    try writeAgentScript(
        """
        while IFS= read -r line; do
          :
        done
        """
    )
}

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
/// - Returns: The script text.
/// - Throws: A JSON-encoding failure.
private func requestLoop(
    answer: String,
    stopReason: StopReason?,
    pidFile: String? = nil,
    transcript: String? = nil,
    argumentsFile: String? = nil,
    asksPermission: Bool = false
) throws -> String {
    """
    \(recordPidStatement(writingTo: pidFile))
    \(recordArgumentsStatement(writingTo: argumentsFile))
    while IFS= read -r line; do
      \(recordRequestStatement(appendingTo: transcript))
      case "$line" in
        *'"method":"initialize"'*)
          \(try printfLine(initializeAnswer()))
          ;;
        *'"method":"session/new"'*)
          \(try printfLine(newSessionAnswer()))
          ;;
        *'"method":"session/prompt"'*)
          \(try printfLine(promptAnswer()))
          \(try permissionExchangeStatements(asking: asksPermission))
          \(try printfLine(messageChunk(answer)))
          \(try printfLine(idleState(stopReason)))
          ;;
      esac
    done
    """
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
              while IFS= read -r permissionAnswer; do
                case "$permissionAnswer" in
                  *'"id":\(permissionRequestID)'*) break ;;
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

/// The `initialize` answer: the protocol version this client supports, the
/// stub's own name and version, and a session capability.
///
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func initializeAnswer() throws -> String {
    try ndjsonLine([
        "id": initializeAnswerID,
        "jsonrpc": jsonRPCVersion,
        "result": [
            "capabilities": ["session": [String: String]()],
            "info": ["name": stubAgentName, "version": stubAgentVersion],
            "protocolVersion": ACPClient.supportedProtocolVersion.rawValue,
        ],
    ])
}

/// The `session/new` answer: the one session id this stub gives out.
///
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func newSessionAnswer() throws -> String {
    try ndjsonLine([
        "id": newSessionAnswerID,
        "jsonrpc": jsonRPCVersion,
        "result": ["sessionId": stubAgentSessionID.rawValue],
    ])
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
