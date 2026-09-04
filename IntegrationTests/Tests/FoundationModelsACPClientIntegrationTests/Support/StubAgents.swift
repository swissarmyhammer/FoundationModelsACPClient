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

/// The non-JSON line ``bannerOnStdoutAgent()`` writes to stdout before it says
/// anything on the wire.
///
/// `cli-plan.md` §10 calls a banner on stdout the most common ACP defect: the
/// agent protocol makes "no non-ACP content on stdout" a MUST, and an agent
/// that breaks it fails in a way that looks like a parsing bug in OUR client.
let stubAgentBannerLine = "stub-agent 1.0.0 — ready"

// MARK: - The three stub agents

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
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func wellBehavedAgent(
    answer: String = stubAgentDefaultAnswer,
    stopReason: StopReason = .endTurn
) throws -> String {
    try writeAgentScript(requestLoop(answer: answer, stopReason: stopReason))
}

/// Writes a stub agent that puts one non-JSON banner line on stdout before its
/// first ndJSON message, and behaves as ``wellBehavedAgent(answer:stopReason:)``
/// after that.
///
/// - Returns: The absolute path of the script; the caller removes it.
/// - Throws: A JSON-encoding failure, or the write failure of the script file.
func bannerOnStdoutAgent() throws -> String {
    try writeAgentScript(
        """
        \(printfLine(stubAgentBannerLine))
        \(requestLoop(answer: stubAgentDefaultAnswer, stopReason: .endTurn))
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
func silentAgent() throws -> String {
    try writeAgentScript(
        """
        while IFS= read -r line; do
          :
        done
        """
    )
}

// MARK: - The script files

/// Writes one agent script into a fresh temporary file.
///
/// - Parameter content: The script text.
/// - Returns: The absolute path of the script file.
/// - Throws: The write failure of the script file.
func writeAgentScript(_ content: String) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("acp-stub-agent-\(UUID().uuidString).sh").path
    try content.write(toFile: path, atomically: true, encoding: .utf8)
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

/// Builds the request loop that every answering stub agent shares.
///
/// The loop reads one ndJSON line at a time and matches the method name as
/// plain text, which is all a shell can do and all this stub needs.
///
/// - Parameters:
///   - answer: The reply text to stream during the prompt turn.
///   - stopReason: The stop reason to end the turn with.
/// - Returns: The script text.
/// - Throws: A JSON-encoding failure.
private func requestLoop(answer: String, stopReason: StopReason) throws -> String {
    """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          \(try printfLine(initializeAnswer()))
          ;;
        *'"method":"session/new"'*)
          \(try printfLine(newSessionAnswer()))
          ;;
        *'"method":"session/prompt"'*)
          \(try printfLine(promptAnswer()))
          \(try printfLine(messageChunk(answer)))
          \(try printfLine(idleState(stopReason)))
          ;;
      esac
    done
    """
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

/// One `state_update` carrying `idle` and the stop reason, which is what ends
/// the turn.
///
/// - Parameter stopReason: The stop reason to report.
/// - Returns: The message as one ndJSON line.
/// - Throws: A JSON-encoding failure.
private func idleState(_ stopReason: StopReason) throws -> String {
    try sessionUpdate([
        "sessionUpdate": "state_update",
        "state": "idle",
        "stopReason": stopReason.wireValue,
    ])
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
