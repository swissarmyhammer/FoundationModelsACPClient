import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Testing

// The tests of the preview factories. This file uses only the public API: it
// has no `@testable import`, so it reads the models as a SwiftUI preview or a
// host app test reads them. Each preview model works with no agent and no
// connection.

/// The kind of a transcript entry, so a test can compare the kinds of a
/// transcript as one list.
private enum EntryKind: Equatable {
    /// A ``UserMessageEntry``.
    case userMessage

    /// An ``AgentMessageEntry``.
    case agentMessage

    /// A ``ThoughtEntry``.
    case thought

    /// A ``ToolCallEntry``.
    case toolCall

    /// A ``PlanTranscriptEntry``.
    case plan

    /// A ``TerminalEntry``.
    case terminal

    /// An ``ErrorEntry``.
    case error

    /// A ``CompactionEntry``.
    case compaction

    /// An ``UnknownEntry``.
    case unknown

    /// Makes the kind of one transcript entry.
    ///
    /// - Parameter entry: The transcript entry.
    init(of entry: TranscriptEntry) {
        switch entry {
        case .userMessage: self = .userMessage
        case .agentMessage: self = .agentMessage
        case .thought: self = .thought
        case .toolCall: self = .toolCall
        case .plan: self = .plan
        case .terminal: self = .terminal
        case .error: self = .error
        case .compaction: self = .compaction
        case .unknown: self = .unknown
        }
    }
}

/// The shared values of the preview factory tests.
private enum PreviewFixtures {
    /// The id of the first session of a preview connection.
    static let firstSessionId = SessionId(rawValue: "preview-first")

    /// The id of the second session of a preview connection.
    static let secondSessionId = SessionId(rawValue: "preview-second")

    /// The working directory of a preview session.
    static let cwd = AbsolutePath(rawValue: "/Users/me/project")

    /// The command of the preview terminal.
    static let terminalCommand = "swift test"

    /// The output of the preview terminal.
    static let terminalOutput = "All tests passed."

    /// The exit code of the preview terminal.
    static let terminalExitCode = 0

    /// The text of the preview user message.
    static let userText = "Fix the failing test."

    /// The text of the user message that a test prompts with.
    static let promptText = "And the other one?"

    /// The title of the preview permission request.
    static let permissionTitle = "Run swift test?"

    /// The "allow" option of the preview permission request.
    static let allowOption = PermissionOption(
        kind: .allowOnce,
        name: "Allow",
        optionId: PermissionOptionId(rawValue: "allow")
    )

    /// The command that the preview agent advertises.
    static let command = AvailableCommand(description: "Run the tests", name: "test")

    /// The MCP server of the preview session.
    static let server = MCPServer.http(MCPServerHTTP(name: "docs", url: "https://example.com/mcp"))

    /// One transcript item of each kind, in the order of ``eachKind``.
    static let oneItemOfEachKind: [PreviewTranscriptItem] = [
        .user(userText),
        .agent("I will run the tests."),
        .thought("The test reads a stale fixture."),
        .toolCall(title: "Read Fixture.swift", kind: .read, status: .completed),
        .plan([PlanEntry(content: "Update the fixture", priority: .high, status: .inProgress)]),
        .terminal(command: terminalCommand, output: terminalOutput, exitCode: terminalExitCode),
        .error(code: .internalError, message: "The agent stopped."),
        .update(.compactionUpdate(CompactionUpdate(compactionId: CompactionId(rawValue: "c-1"), status: .completed))),
        .update(.unknown("future_update", .object([:]))),
    ]

    /// The kind of each item of ``oneItemOfEachKind``, in order.
    static let eachKind: [EntryKind] = [
        .userMessage, .agentMessage, .thought, .toolCall, .plan, .terminal, .error, .compaction, .unknown,
    ]

    /// Makes the permission request of a preview session.
    ///
    /// - Parameter sessionId: The id of the session.
    /// - Returns: The request.
    static func permissionRequest(for sessionId: SessionId) -> RequestPermissionRequest {
        RequestPermissionRequest(options: [allowOption], sessionId: sessionId, title: permissionTitle)
    }
}

@MainActor
extension TranscriptEntry {
    /// The text of each text block of a message entry, joined in order, or
    /// `nil` for an entry that is not a message.
    fileprivate var messageText: String? {
        let content: [ContentBlock]
        switch self {
        case .userMessage(let entry): content = entry.content
        case .agentMessage(let entry): content = entry.content
        case .thought(let entry): content = entry.content
        case .toolCall, .plan, .terminal, .error, .compaction, .unknown: return nil
        }
        return content.map { block in
            if case .text(let text) = block { text.text } else { "" }
        }
        .joined()
    }

    /// The user-message object, or `nil` for another kind.
    fileprivate var userMessageEntry: UserMessageEntry? {
        if case .userMessage(let entry) = self { entry } else { nil }
    }

    /// The terminal object, or `nil` for another kind.
    fileprivate var terminalEntry: TerminalEntry? {
        if case .terminal(let entry) = self { entry } else { nil }
    }

    /// The tool-call object, or `nil` for another kind.
    fileprivate var toolCallEntry: ToolCallEntry? {
        if case .toolCall(let entry) = self { entry } else { nil }
    }

    /// The timing of the entry, for each kind.
    fileprivate var entryTiming: EntryTiming {
        switch self {
        case .userMessage(let entry): entry.timing
        case .agentMessage(let entry): entry.timing
        case .thought(let entry): entry.timing
        case .toolCall(let entry): entry.timing
        case .plan(let entry): entry.timing
        case .terminal(let entry): entry.timing
        case .error(let entry): entry.timing
        case .compaction(let entry): entry.timing
        case .unknown(let entry): entry.timing
        }
    }
}

@MainActor
struct PreviewFactoryTests {
    // MARK: - SessionModel.preview

    @Test func aPreviewSessionHoldsOneEntryOfEachKindInItsOrder() {
        let model = SessionModel.preview(transcript: PreviewFixtures.oneItemOfEachKind)

        #expect(model.transcript.map(EntryKind.init(of:)) == PreviewFixtures.eachKind)
    }

    @Test func aPreviewUserMessageHasItsTextAndIsSent() throws {
        let model = SessionModel.preview(transcript: [.user(PreviewFixtures.userText)])

        let entry = try #require(model.transcript.first)
        #expect(entry.messageText == PreviewFixtures.userText)
        #expect(try #require(entry.userMessageEntry).sendState == .sent)
    }

    @Test func twoAgentItemsInARowAreTwoMessages() {
        let model = SessionModel.preview(transcript: [.agent("First."), .agent("Second.")])

        #expect(model.transcript.map(\.messageText) == ["First.", "Second."])
    }

    @Test func aPreviewToolCallHasItsTitleKindAndStatus() throws {
        let model = SessionModel.preview(transcript: [.toolCall(title: "Read", kind: .read, status: .inProgress)])

        let entry = try #require(model.transcript.first?.toolCallEntry)
        #expect(entry.title == "Read")
        #expect(entry.kind == .read)
        #expect(entry.status == .inProgress)
    }

    @Test func aPreviewTerminalHasItsCommandOutputAndExitCode() throws {
        let model = SessionModel.preview(transcript: [
            .terminal(
                command: PreviewFixtures.terminalCommand,
                output: PreviewFixtures.terminalOutput,
                exitCode: PreviewFixtures.terminalExitCode
            )
        ])

        let entry = try #require(model.transcript.first?.terminalEntry)
        #expect(entry.command == PreviewFixtures.terminalCommand)
        #expect(entry.text == PreviewFixtures.terminalOutput)
        #expect(entry.exitStatus?.exitCode == PreviewFixtures.terminalExitCode)
    }

    @Test func eachPreviewEntryStartsAtThePreviewDate() {
        let model = SessionModel.preview(transcript: PreviewFixtures.oneItemOfEachKind)

        #expect(model.transcript.allSatisfy { $0.entryTiming.startedAt == SessionModel.previewDate })
    }

    @Test func aPreviewSessionHoldsItsIdWorkingDirectoryCommandsOptionsAndServers() {
        let model = SessionModel.preview(
            sessionId: PreviewFixtures.firstSessionId,
            cwd: PreviewFixtures.cwd,
            availableCommands: [PreviewFixtures.command],
            configOptions: [],
            mcpServers: [PreviewFixtures.server]
        )

        #expect(model.sessionId == PreviewFixtures.firstSessionId)
        #expect(model.cwd == PreviewFixtures.cwd)
        #expect(model.availableCommands == [PreviewFixtures.command])
        #expect(model.configOptions == [])
        #expect(model.mcpServers.map(\.name) == ["docs"])
    }

    @Test func aPreviewSessionHoldsItsPendingPermissionsAtOnce() {
        let model = SessionModel.preview(
            pendingPermissions: [PreviewFixtures.permissionRequest(for: PreviewFixtures.firstSessionId)]
        )

        #expect(model.pendingPermissions.map(\.request.title) == [PreviewFixtures.permissionTitle])
    }

    @Test func aSelectedPreviewPermissionLeavesThePendingList() async throws {
        let model = SessionModel.preview(
            pendingPermissions: [PreviewFixtures.permissionRequest(for: PreviewFixtures.firstSessionId)]
        )
        let pending = try #require(model.pendingPermissions.first)

        await model.selectPermission(pending.id, option: PreviewFixtures.allowOption.optionId)

        #expect(model.pendingPermissions.isEmpty)
    }

    // MARK: - The preview request sender

    @Test func aPreviewPromptAddsAUserMessageThatTheAnswerMarksSent() async throws {
        let model = SessionModel.preview()

        _ = try await model.prompt([.text(TextContent(text: PreviewFixtures.promptText))])

        let entry = try #require(model.transcript.last)
        #expect(entry.messageText == PreviewFixtures.promptText)
        #expect(try #require(entry.userMessageEntry).sendState == .sent)
    }

    @Test func twoPreviewPromptsGiveTwoMessageIds() async throws {
        let model = SessionModel.preview()
        let prompt: [ContentBlock] = [.text(TextContent(text: PreviewFixtures.promptText))]

        let first = try await model.prompt(prompt)
        let second = try await model.prompt(prompt)

        #expect(first.messageId != second.messageId)
    }

    @Test func aPromptThatNeverAnswersStaysPendingUntilItsTaskIsCancelled() async throws {
        let model = SessionModel.preview(requestSender: PreviewSessionRequestSender(answer: .never))
        let call = Task.immediate { @MainActor in
            try await model.prompt([.text(TextContent(text: PreviewFixtures.promptText))])
        }
        let entry = try #require(model.transcript.last?.userMessageEntry)
        #expect(entry.sendState == .pending)

        call.cancel()
        _ = await call.result

        #expect(entry.sendState == .failed)
    }

    @Test func aPreviewCancelAndConfigChangeLeaveTheTranscriptAsItIs() async throws {
        let model = SessionModel.preview(transcript: [.user(PreviewFixtures.userText)])
        let change = SetSessionConfigOptionRequest(
            configId: SessionConfigId(rawValue: "mode"),
            sessionId: model.sessionId,
            value: .id(SessionConfigValueId(rawValue: "fast"))
        )

        try await model.cancel()
        try await model.setConfigOption(change)

        #expect(model.transcript.count == 1)
    }

    // MARK: - ConnectionModel.preview

    @Test func aPreviewConnectionHoldsTwoOpenSessionsInOrder() {
        let first = SessionModel.preview(sessionId: PreviewFixtures.firstSessionId)
        let second = SessionModel.preview(sessionId: PreviewFixtures.secondSessionId)

        let model = ConnectionModel.preview(openSessions: [first, second])

        #expect(model.openSessions.map(\.id) == [PreviewFixtures.firstSessionId, PreviewFixtures.secondSessionId])
        #expect(model.session(for: PreviewFixtures.secondSessionId) === second)
    }

    @Test func aPreviewConnectionHoldsItsStateSessionsAuthStateAndInitializeResponse() {
        let listed = SessionInfo(cwd: PreviewFixtures.cwd, sessionId: PreviewFixtures.firstSessionId, title: "Tests")
        let response = InitializeResponse(
            info: Implementation(name: "preview-agent", version: "1.0.0"),
            protocolVersion: ACPClient.supportedProtocolVersion
        )

        let model = ConnectionModel.preview(
            state: .disconnected,
            sessions: [listed],
            authState: .notRequired,
            initializeResponse: response
        )

        #expect(model.state == .disconnected)
        #expect(model.sessions == [listed])
        #expect(model.authState == .notRequired)
        #expect(model.initializeResponse == response)
    }

    @Test func aPreviewConnectionSendsNoRequest() async {
        let model = ConnectionModel.preview()

        await #expect(throws: ConnectionError.self) {
            _ = try await model.newSession(NewSessionRequest(cwd: PreviewFixtures.cwd))
        }
        #expect(model.openSessions.isEmpty)
    }

    // MARK: - Samples

    @Test func theSessionSampleHasAConversationAToolCallAndAPendingPermission() {
        let model = SessionModel.previewSample

        let kinds = model.transcript.map(EntryKind.init(of:))
        #expect(kinds.contains(.userMessage))
        #expect(kinds.contains(.agentMessage))
        #expect(kinds.filter { $0 == .toolCall }.count == 1)
        #expect(model.pendingPermissions.count == 1)
    }

    @Test func eachSessionSampleIsANewModel() {
        #expect(SessionModel.previewSample !== SessionModel.previewSample)
    }

    @Test func theConnectionSampleHasTwoOpenSessionsThatItLists() {
        let model = ConnectionModel.previewSample

        #expect(model.state == .connected)
        #expect(model.openSessions.count == 2)
        #expect(model.sessions.map(\.sessionId) == model.openSessions.map(\.id))
    }
}
