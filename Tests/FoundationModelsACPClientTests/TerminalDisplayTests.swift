import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// These tests drive the terminal rendering surface over the real ACP wire.
// A scripted stub agent runs behind `InMemoryTransport.pair()` and sends the
// terminal updates during one prompt turn. The assertions read the final
// observable state.

/// Two bytes that are not valid in any UTF-8 sequence. `0xFF` and `0xFE`
/// do not appear in well-formed UTF-8, so a lossy decode turns each one
/// into the Unicode replacement character.
private let bytesOutsideUTF8 = Data([UInt8.max, UInt8.max - 1])

/// Makes a terminal-output-chunk update that carries `text` as
/// base64-encoded bytes.
///
/// - Parameters:
///   - text: The text of the chunk.
///   - terminal: The terminal that receives the bytes.
/// - Returns: The update.
private func terminalChunk(_ text: String, for terminal: TerminalId) -> SessionUpdate {
    .terminalOutputChunk(
        TerminalOutputChunk(data: Data(text.utf8).base64EncodedString(), terminalId: terminal)
    )
}

/// Drives one prompt turn in which the stub agent sends `script`, and
/// returns the final session state.
///
/// - Parameter script: The updates the stub agent sends, in order.
/// - Returns: The session state after the turn.
@MainActor
private func stateAfterPromptTurn(sending script: [SessionUpdate]) async throws -> ACPSessionState {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let model = SwiftUIACPClient()
    let connection = await ClientSideConnection(stream: clientEnd) { _ in model }
    let agentConnection = await AgentSideConnection(stream: agentEnd) { agentSide in
        ScriptedStubAgent(connection: agentSide, session: testSession, script: script)
    }
    _ = try await connection.prompt(
        PromptRequest(prompt: [textBlock("go")], sessionId: testSession)
    )
    let state = model.session(for: testSession)
    state.flushPendingChunks()
    await connection.close()
    withExtendedLifetime(agentConnection) {}
    return state
}

@MainActor @Test(.timeLimit(.minutes(1)))
func interleavedChunksAccumulateTheConcatenatedBytesForEachTerminal() async throws {
    let first = TerminalId(rawValue: "term-first")
    let second = TerminalId(rawValue: "term-second")

    let state = try await stateAfterPromptTurn(sending: [
        .terminalUpdate(TerminalUpdate(terminalId: first, command: .value("swift build"))),
        terminalChunk("one ", for: first),
        terminalChunk("alpha ", for: second),
        terminalChunk("two ", for: first),
        terminalChunk("beta", for: second),
        terminalChunk("three", for: first),
    ])

    #expect(state.terminals[first]?.output == Data("one two three".utf8))
    #expect(state.terminals[second]?.output == Data("alpha beta".utf8))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func snapshotOnTerminalUpdateReplacesTheAccumulatedOutput() async throws {
    let terminalID = TerminalId(rawValue: "term-snapshot")

    let state = try await stateAfterPromptTurn(sending: [
        terminalChunk("first ", for: terminalID),
        terminalChunk("second ", for: terminalID),
        .terminalUpdate(
            TerminalUpdate(
                terminalId: terminalID,
                output: .value(TerminalOutput(data: Data("fresh ".utf8).base64EncodedString()))
            )
        ),
        terminalChunk("third", for: terminalID),
    ])

    let output = try #require(state.terminals[terminalID]?.output)
    #expect(output == Data("fresh third".utf8))
    // The length assertion catches an append defect: an appended transcript
    // holds the earlier chunks as well, so it is longer.
    #expect(output.count == "fresh third".utf8.count)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func invalidBase64ChunkIsDroppedWithoutCorruptingTheOutput() async throws {
    let terminalID = TerminalId(rawValue: "term-bad-chunk")

    let state = try await stateAfterPromptTurn(sending: [
        terminalChunk("good ", for: terminalID),
        .terminalOutputChunk(
            TerminalOutputChunk(data: "!!! not base64 !!!", terminalId: terminalID)
        ),
        terminalChunk("still good", for: terminalID),
    ])

    #expect(state.terminals[terminalID]?.output == Data("good still good".utf8))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func invalidBase64SnapshotKeepsTheStoredOutput() async throws {
    let terminalID = TerminalId(rawValue: "term-bad-snapshot")

    let state = try await stateAfterPromptTurn(sending: [
        terminalChunk("kept", for: terminalID),
        .terminalUpdate(
            TerminalUpdate(
                terminalId: terminalID,
                output: .value(TerminalOutput(data: "!!! not base64 !!!"))
            )
        ),
    ])

    #expect(state.terminals[terminalID]?.output == Data("kept".utf8))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nonUTF8BytesSurviveToTheReplacementCharacterTranscript() async throws {
    let terminalID = TerminalId(rawValue: "term-bytes")
    let raw = Data("size ".utf8) + bytesOutsideUTF8 + Data(" done".utf8)

    let state = try await stateAfterPromptTurn(sending: [
        .terminalOutputChunk(
            TerminalOutputChunk(data: raw.base64EncodedString(), terminalId: terminalID)
        )
    ])

    let terminal = try #require(state.terminals[terminalID])
    // The raw bytes stay complete: the rendering fallback drops no data.
    #expect(terminal.output == raw)
    // Each invalid byte renders as the Unicode replacement character.
    #expect(terminal.transcript == "size \u{FFFD}\u{FFFD} done")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func terminalUpdateForAnUnseenIdCreatesTheTerminal() async throws {
    let terminalID = TerminalId(rawValue: "term-new")
    let cwd = try #require(AbsolutePath(rawValue: "/workspace/project"))
    let exitStatus = TerminalExitStatus(exitCode: 0)

    let state = try await stateAfterPromptTurn(sending: [
        .terminalUpdate(
            TerminalUpdate(
                terminalId: terminalID,
                command: .value("swift test"),
                cwd: .value(cwd),
                exitStatus: .value(exitStatus)
            )
        )
    ])

    let terminal = try #require(state.terminals[terminalID])
    #expect(terminal.command == .value("swift test"))
    #expect(terminal.cwd == .value(cwd))
    #expect(terminal.exitStatus == .value(exitStatus))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func terminalContentReferenceResolvesToItsTerminal() async throws {
    let terminalID = TerminalId(rawValue: "term-referenced")
    let callID = ToolCallId(rawValue: "call-terminal")

    let state = try await stateAfterPromptTurn(sending: [
        .terminalUpdate(TerminalUpdate(terminalId: terminalID, command: .value("ls"))),
        terminalChunk("listing", for: terminalID),
        .toolCallContentChunk(
            ToolCallContentChunk(
                content: .terminal(Terminal(terminalId: terminalID)),
                toolCallId: callID
            )
        ),
    ])

    let content = try #require(state.toolCalls[callID]?.content)
    guard case .value(let items) = content, case .terminal(let reference)? = items.first else {
        Issue.record("the tool call does not hold the terminal reference")
        return
    }
    let terminal = try #require(state.terminal(for: reference))
    #expect(terminal.command == .value("ls"))
    #expect(terminal.output == Data("listing".utf8))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func terminalContentReferenceToAnUnknownIdResolvesToNil() async throws {
    let state = try await stateAfterPromptTurn(sending: [])
    let reference = Terminal(terminalId: TerminalId(rawValue: "term-unknown"))

    #expect(state.terminal(for: reference) == nil)
}
