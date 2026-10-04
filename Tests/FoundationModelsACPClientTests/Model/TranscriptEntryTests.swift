import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the observable transcript entry classes. Each wire entry comes
// from the FoundationModelsACP merge engine, because the upstream entry value
// has no public initializer. This file writes `FoundationModelsACP.SessionEntry`
// in full, so each use names the module of the engine value.

extension SessionMergeEngine.Change {
    /// The entry that this change added or changed, or `nil` for a change of
    /// a last-value field and for a notice.
    fileprivate var entry: FoundationModelsACP.SessionEntry? {
        switch self {
        case .entryAdded(_, let entry), .entryChanged(_, let entry):
            entry
        case .availableCommandsChanged, .configOptionsChanged, .usageChanged, .agentStateChanged, .sessionInfoChanged,
            .notice:
            nil
        }
    }
}

/// Applies each update to a new merge engine, and gives the entry that the
/// last update added or changed.
///
/// - Parameter updates: The updates to apply, in order.
/// - Returns: The engine entry of the last change.
/// - Throws: When the last change is not an entry change.
private func engineEntry(after updates: SessionUpdate...) throws -> FoundationModelsACP.SessionEntry {
    var engine = SessionMergeEngine()
    let changes = updates.map { engine.apply($0) }
    return try #require(changes.last?.entry)
}

/// A JSON object with one string member, for the `_meta` fields.
///
/// - Parameter value: The value of the `trace` member.
/// - Returns: The JSON object.
private func metaObject(_ value: String) -> JSONValue {
    .object(["trace": .string(value)])
}

/// A tool-call update with each field set.
private let fullToolCall = ToolCallUpdate(
    toolCallId: ToolCallId(rawValue: "tool-1"),
    content: .value([.content(Content(content: textBlock("read 3 lines")))]),
    kind: .value(.read),
    locations: .value([ToolCallLocation(path: AbsolutePath(rawValue: "/tmp/notes.txt"))]),
    name: .value("read_file"),
    rawInput: .value(.object(["path": .string("/tmp/notes.txt")])),
    rawOutput: .value(.string("three lines")),
    status: .value(.completed),
    title: .value("Read notes.txt"),
    meta: .value(metaObject("tool"))
)

/// A terminal update with each field set. The output is "hi" in base64.
private let fullTerminal = TerminalUpdate(
    terminalId: TerminalId(rawValue: "terminal-1"),
    command: .value("ls"),
    cwd: .value(AbsolutePath(rawValue: "/tmp")),
    exitStatus: .value(TerminalExitStatus(exitCode: 0)),
    output: .value(TerminalOutput(data: Data("hi".utf8).base64EncodedString())),
    meta: .value(metaObject("terminal"))
)

/// The plan id that the plan tests use.
private let testPlanId = PlanId(rawValue: "plan-1")

/// A plan update with one item.
private let onePlan = PlanUpdate(
    plan: .items(PlanItems(entries: [PlanEntry(content: "Read the notes", priority: .high, status: .pending)], planId: testPlanId)),
    meta: metaObject("plan")
)

/// A byte that is never valid in UTF-8.
private let invalidUTF8Byte: UInt8 = 0xFF

// MARK: - The factory and update(from:) for each kind

@MainActor @Test func userMessageUpdateCopiesContentMessageIdAndMeta() throws {
    let messageId = MessageId(rawValue: "user-1")
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: userChunk(text: "Hello"))).userMessage)

    let whole = UserMessage(messageId: messageId, content: .value([textBlock("Hello there")]), meta: .value(metaObject("user")))
    entry.update(from: try engineEntry(after: userChunk(text: "Hello"), .userMessage(whole)))

    #expect(entry.id == .wire(.userMessage(messageId)))
    #expect(entry.origin == .wire)
    #expect(entry.messageId == messageId)
    #expect(entry.content == [textBlock("Hello there")])
    #expect(entry.meta == metaObject("user"))
    #expect(entry.sendState == .sent)
}

@MainActor @Test func agentMessageUpdateAppendsTheNextChunk() throws {
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: agentChunk(text: "Hel"))).agentMessage)

    entry.update(from: try engineEntry(after: agentChunk(text: "Hel"), agentChunk(text: "lo")))

    #expect(entry.id == .wire(.agentMessage(MessageId(rawValue: "agent-1"))))
    #expect(entry.origin == .wire)
    #expect(entry.messageId == MessageId(rawValue: "agent-1"))
    #expect(entry.content == [textBlock("Hel"), textBlock("lo")])
    #expect(entry.meta == nil)
}

@MainActor @Test func thoughtUpdateCopiesContentAndMeta() throws {
    let messageId = MessageId(rawValue: "thought-1")
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: thoughtChunk(text: "Think"))).thought)

    let whole = AgentThought(messageId: messageId, content: .value([textBlock("Thinking")]), meta: .value(metaObject("thought")))
    entry.update(from: try engineEntry(after: thoughtChunk(text: "Think"), .agentThought(whole)))

    #expect(entry.id == .wire(.agentThought(messageId)))
    #expect(entry.origin == .wire)
    #expect(entry.messageId == messageId)
    #expect(entry.content == [textBlock("Thinking")])
    #expect(entry.meta == metaObject("thought"))
}

@MainActor @Test func eachMessageClassFindsTheMessageOfItsOwnKindOnly() throws {
    let userKind = try engineEntry(after: userChunk(text: "Hi")).kind
    let agentKind = try engineEntry(after: agentChunk(text: "Hello")).kind
    let thoughtKind = try engineEntry(after: thoughtChunk(text: "Hmm")).kind

    #expect(UserMessageEntry.message(in: userKind)?.content == [textBlock("Hi")])
    #expect(AgentMessageEntry.message(in: agentKind)?.content == [textBlock("Hello")])
    #expect(ThoughtEntry.message(in: thoughtKind)?.content == [textBlock("Hmm")])
    #expect(UserMessageEntry.message(in: agentKind) == nil)
    #expect(AgentMessageEntry.message(in: thoughtKind) == nil)
    #expect(ThoughtEntry.message(in: userKind) == nil)
}

@MainActor @Test func toolCallUpdateCopiesEveryField() throws {
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: toolCallStatus(id: "tool-1", .pending))).toolCall)
    #expect(entry.status == .pending)
    #expect(entry.name == nil)

    entry.update(from: try engineEntry(after: .toolCallUpdate(fullToolCall)))

    #expect(entry.id == .wire(.toolCall(ToolCallId(rawValue: "tool-1"))))
    #expect(entry.origin == .wire)
    #expect(entry.name == "read_file")
    #expect(entry.title == "Read notes.txt")
    #expect(entry.kind == .read)
    #expect(entry.status == .completed)
    #expect(entry.content == [.content(Content(content: textBlock("read 3 lines")))])
    #expect(entry.locations == [ToolCallLocation(path: AbsolutePath(rawValue: "/tmp/notes.txt"))])
    #expect(entry.rawInput == .object(["path": .string("/tmp/notes.txt")]))
    #expect(entry.rawOutput == .string("three lines"))
    #expect(entry.meta == metaObject("tool"))
    #expect(entry.linkedElicitationIDs.isEmpty)
}

@MainActor @Test func terminalUpdateCopiesBytesExitStatusCommandAndDirectory() throws {
    let terminalId = TerminalId(rawValue: "terminal-1")
    let first = try engineEntry(after: .terminalUpdate(TerminalUpdate(terminalId: terminalId)))
    let entry = try #require(TranscriptEntry(wire: first).terminal)
    #expect(entry.bytes.isEmpty)

    entry.update(from: try engineEntry(after: .terminalUpdate(fullTerminal)))

    #expect(entry.id == .wire(.terminal(terminalId)))
    #expect(entry.origin == .wire)
    #expect(entry.bytes == Data("hi".utf8))
    #expect(entry.text == "hi")
    #expect(entry.exitStatus == TerminalExitStatus(exitCode: 0))
    #expect(entry.command == "ls")
    #expect(entry.cwd == AbsolutePath(rawValue: "/tmp"))
    #expect(entry.meta == metaObject("terminal"))
}

@MainActor @Test func terminalTextReplacesBadUTF8Bytes() throws {
    let badBytes = Data([UInt8(ascii: "o"), UInt8(ascii: "k"), invalidUTF8Byte])
    let chunk = TerminalOutputChunk(data: badBytes.base64EncodedString(), terminalId: TerminalId(rawValue: "terminal-1"))
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: .terminalOutputChunk(chunk))).terminal)

    #expect(entry.bytes == badBytes)
    #expect(entry.text == "ok\u{FFFD}")
}

@MainActor @Test func planUpdateCopiesPlanIdEntriesAndMeta() throws {
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: .planUpdate(onePlan))).plan)
    #expect(entry.meta == metaObject("plan"))

    let replacement = PlanUpdate(
        plan: .items(PlanItems(entries: [PlanEntry(content: "Write the answer", priority: .low, status: .inProgress)], planId: testPlanId))
    )
    entry.update(from: try engineEntry(after: .planUpdate(onePlan), .planUpdate(replacement)))

    #expect(entry.id == .wire(.plan(testPlanId)))
    #expect(entry.origin == .wire)
    #expect(entry.planId == testPlanId)
    #expect(entry.entries == [PlanEntry(content: "Write the answer", priority: .low, status: .inProgress)])
    // The engine rule: a plan update without `_meta` keeps the `_meta` of the plan.
    #expect(entry.meta == metaObject("plan"))
}

@MainActor @Test func planUpdateOfUnknownContentKeepsTheTypeAndThePayload() throws {
    let payload: JSONValue = .object(["steps": .array([.string("Read the notes")])])
    let update = PlanUpdate(plan: .unknown("future_plan", payload))
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: .planUpdate(update))).plan)

    #expect(entry.unknownContent == PlanTranscriptEntry.UnknownContent(type: "future_plan", payload: payload))
    #expect(entry.entries.isEmpty)
}

@MainActor @Test func planUpdateOfItemsHasNoUnknownContent() throws {
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: .planUpdate(onePlan))).plan)

    #expect(entry.unknownContent == nil)
    #expect(!entry.entries.isEmpty)
}

@MainActor @Test func unknownUpdateKeepsTheTypeAndTheRawPayload() throws {
    let payload: JSONValue = .object(["note": .string("new"), "_meta": metaObject("unknown")])
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: .unknown("future_update", payload))).unknown)

    #expect(entry.id == .wire(.unidentified(position: 0)))
    #expect(entry.origin == .wire)
    #expect(entry.type == "future_update")
    #expect(entry.raw == payload)
    #expect(entry.meta == metaObject("unknown"))
}

@MainActor @Test func errorEntryHoldsTheCodeMessageAndData() {
    let entry = ErrorEntry(code: .internalError, message: "The agent failed", data: .string("stack"))

    #expect(entry.origin == .local)
    #expect(entry.code == .internalError)
    #expect(entry.message == "The agent failed")
    #expect(entry.data == .string("stack"))
    #expect(entry.meta == nil)
    #expect(TranscriptEntry.error(entry).id == entry.id)
}

// MARK: - Observation

@MainActor @Test func equalToolCallUpdateFiresNoObservation() throws {
    let wire = try engineEntry(after: .toolCallUpdate(fullToolCall))
    let entry = try #require(TranscriptEntry(wire: wire).toolCall)

    let fired = observationFires {
        _ = (entry.name, entry.title, entry.kind, entry.status, entry.content)
        _ = (entry.locations, entry.rawInput, entry.rawOutput, entry.meta, entry.linkedElicitationIDs)
    } during: {
        entry.update(from: wire)
    }

    #expect(!fired)
}

@MainActor @Test func equalMessageUpdatesFireNoObservation() throws {
    let userWire = try engineEntry(after: userChunk(text: "Hi"))
    let agentWire = try engineEntry(after: agentChunk(text: "Hello"))
    let thoughtWire = try engineEntry(after: thoughtChunk(text: "Hmm"))
    let user = try #require(TranscriptEntry(wire: userWire).userMessage)
    let agent = try #require(TranscriptEntry(wire: agentWire).agentMessage)
    let thought = try #require(TranscriptEntry(wire: thoughtWire).thought)

    let fired = observationFires {
        _ = (user.content, user.messageId, user.meta, user.sendState)
        _ = (agent.content, agent.messageId, agent.meta)
        _ = (thought.content, thought.messageId, thought.meta)
    } during: {
        user.update(from: userWire)
        agent.update(from: agentWire)
        thought.update(from: thoughtWire)
    }

    #expect(!fired)
}

@MainActor @Test func equalTerminalPlanAndUnknownUpdatesFireNoObservation() throws {
    let terminalWire = try engineEntry(after: .terminalUpdate(fullTerminal))
    let planWire = try engineEntry(after: .planUpdate(onePlan))
    let unknownWire = try engineEntry(after: .unknown("future_update", .object(["note": .string("new")])))
    let terminal = try #require(TranscriptEntry(wire: terminalWire).terminal)
    let plan = try #require(TranscriptEntry(wire: planWire).plan)
    let unknown = try #require(TranscriptEntry(wire: unknownWire).unknown)

    let fired = observationFires {
        _ = (terminal.bytes, terminal.exitStatus, terminal.command, terminal.cwd, terminal.meta)
        _ = (plan.planId, plan.entries, plan.meta, plan.unknownContent)
        _ = (unknown.type, unknown.raw, unknown.meta)
    } during: {
        terminal.update(from: terminalWire)
        plan.update(from: planWire)
        unknown.update(from: unknownWire)
    }

    #expect(!fired)
}

@MainActor @Test func changedMessageUpdateFiresTheObservation() throws {
    let entry = try #require(TranscriptEntry(wire: try engineEntry(after: agentChunk(text: "Hel"))).agentMessage)
    let second = try engineEntry(after: agentChunk(text: "Hel"), agentChunk(text: "lo"))

    let fired = observationFires {
        _ = entry.content
    } during: {
        entry.update(from: second)
    }

    #expect(fired)
}

// MARK: - The local user message

@MainActor @Test func localUserMessageStartsPendingWithNoMessageId() {
    let entry = UserMessageEntry(content: [textBlock("Hello")], meta: metaObject("local"))

    #expect(entry.origin == .local)
    #expect(entry.sendState == .pending)
    #expect(entry.messageId == nil)
    #expect(entry.content == [textBlock("Hello")])
    #expect(entry.meta == metaObject("local"))
}

@MainActor @Test func linkingALocalUserMessageKeepsItsId() {
    let entry = UserMessageEntry(content: [textBlock("Hello")], meta: nil)
    let idBeforeLink = entry.id

    entry.messageId = MessageId(rawValue: "prompted-user-1")
    entry.sendState = .sent

    #expect(entry.id == idBeforeLink)
    #expect(TranscriptEntry.userMessage(entry).id == idBeforeLink)
    #expect(entry.origin == .local)
}

@MainActor @Test func echoUpdateOnALocalUserMessageKeepsItsIdAndOrigin() throws {
    let entry = UserMessageEntry(content: [textBlock("Hello")], meta: nil)
    let idBeforeEcho = entry.id

    entry.update(from: try engineEntry(after: userChunk(text: "Hello", message: "prompted-user-1")))

    #expect(entry.id == idBeforeEcho)
    #expect(entry.origin == .local)
    #expect(entry.messageId == MessageId(rawValue: "prompted-user-1"))
    #expect(entry.content == [textBlock("Hello")])
}
