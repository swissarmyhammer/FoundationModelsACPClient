import Foundation
import FoundationModelsACP
import Logging
import Observation

/// Where a transcript entry came from.
public enum EntryOrigin: Hashable, Sendable {
    /// The agent sent the entry on the wire, or the session merge engine made
    /// it from a wire update.
    case wire

    /// The client made the entry itself, for example a user message before
    /// the agent echoes it, or an error of a request.
    case local
}

/// The send state of a user message.
public enum SendState: Hashable, Sendable {
    /// The client sent the prompt, and the agent did not link the message yet.
    case pending

    /// The agent has the message. A user message from the wire is always in
    /// this state.
    case sent

    /// The prompt request failed.
    case failed
}

/// One entry of a session transcript, as an observable object.
///
/// Each case holds one `@MainActor @Observable` object. A streamed chunk
/// changes only the object of its own entry, so SwiftUI redraws only that
/// row. A `ForEach` keys on ``id``, which never changes for the life of the
/// object.
///
/// The FoundationModelsACP session merge engine owns the merge rules. The
/// objects keep no merge rules of their own: each `update(from:)` copies the
/// merged engine value.
public enum TranscriptEntry: Identifiable, Sendable {
    /// A message from the user.
    case userMessage(UserMessageEntry)

    /// A message from the agent.
    case agentMessage(AgentMessageEntry)

    /// A thought (reasoning) from the agent.
    case thought(ThoughtEntry)

    /// A tool call.
    case toolCall(ToolCallEntry)

    /// An agent-owned terminal.
    case terminal(TerminalEntry)

    /// A plan.
    case plan(PlanTranscriptEntry)

    /// A session update that this revision of the schema does not know.
    case unknown(UnknownEntry)

    /// **UNSTABLE** A context compaction. It changes no earlier entry.
    case compaction(CompactionEntry)

    /// An error that the client shows in the transcript.
    case error(ErrorEntry)

    /// The stable identity of a transcript entry.
    public enum ID: Hashable, Sendable {
        /// The identity of an entry from the wire: the identifier that the
        /// session merge engine gives the entry.
        case wire(FoundationModelsACP.SessionEntry.ID)

        /// The identity of an entry that the client made. A local user
        /// message keeps this identity also after the agent links it to a
        /// `messageId`.
        case local(UUID)

        /// The origin that this identity tells.
        public var origin: EntryOrigin {
            switch self {
            case .wire: .wire
            case .local: .local
            }
        }
    }

    /// The stable identity of the entry.
    public var id: ID {
        switch self {
        case .userMessage(let entry): entry.id
        case .agentMessage(let entry): entry.id
        case .thought(let entry): entry.id
        case .toolCall(let entry): entry.id
        case .terminal(let entry): entry.id
        case .plan(let entry): entry.id
        case .unknown(let entry): entry.id
        case .compaction(let entry): entry.id
        case .error(let entry): entry.id
        }
    }

    /// Makes the observable entry for an entry of the session merge engine.
    ///
    /// - Parameter entry: The engine entry, which the engine gave in an
    ///   `entryAdded` change.
    @MainActor
    init(wire entry: FoundationModelsACP.SessionEntry) {
        switch entry.kind {
        case .userMessage: self = .userMessage(UserMessageEntry(wire: entry))
        case .agentMessage: self = .agentMessage(AgentMessageEntry(wire: entry))
        case .agentThought: self = .thought(ThoughtEntry(wire: entry))
        case .toolCall: self = .toolCall(ToolCallEntry(wire: entry))
        case .terminal: self = .terminal(TerminalEntry(wire: entry))
        case .plan: self = .plan(PlanTranscriptEntry(wire: entry))
        case .unknown: self = .unknown(UnknownEntry(wire: entry))
        case .compaction(let compaction): self = .compaction(CompactionEntry(wire: entry, compaction: compaction))
        }
    }

    /// Copies the merged state of an engine entry into the object of this
    /// entry. Only that one object changes.
    ///
    /// The engine never changes a local error entry, so an error entry
    /// records the kind mismatch and stays unchanged.
    ///
    /// - Parameter entry: The engine entry, which the engine gave in an
    ///   `entryChanged` change.
    @MainActor
    func update(from entry: FoundationModelsACP.SessionEntry) {
        switch self {
        case .userMessage(let object): object.update(from: entry)
        case .agentMessage(let object): object.update(from: entry)
        case .thought(let object): object.update(from: entry)
        case .toolCall(let object): object.update(from: entry)
        case .terminal(let object): object.update(from: entry)
        case .plan(let object): object.update(from: entry)
        case .unknown(let object): object.update(from: entry)
        case .compaction(let object): object.update(from: entry)
        case .error(let object): object.recordKindMismatch()
        }
    }
}

/// The members that each observable transcript entry object has.
@MainActor
public protocol ObservableTranscriptEntry: AnyObject, Observable, Identifiable where ID == TranscriptEntry.ID {
    /// The `_meta` field of the entry, folded with the patch rules of the
    /// session merge engine, or `nil` when the entry has none.
    var meta: JSONValue? { get }
}

extension ObservableTranscriptEntry {
    /// Where the entry came from. The identity tells it, so the origin never
    /// changes for the life of the object.
    public nonisolated var origin: EntryOrigin {
        id.origin
    }
}

extension ObservableTranscriptEntry {
    /// Writes a value to a property only when the value is different.
    ///
    /// Observation then sees no write for a property that did not change, so
    /// a row that shows only that property is not invalidated. The setter
    /// that the `@Observable` macro of this toolchain makes also skips the
    /// notification for an equal `Equatable` value; this check keeps the
    /// contract when the macro does not.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - keyPath: The property to write.
    func assign<Value: Equatable>(_ value: Value, to keyPath: ReferenceWritableKeyPath<Self, Value>) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    /// Records an engine entry of another kind than this object.
    ///
    /// The engine identity tells the kind, so a caller that finds the object
    /// by identity never gets here. The assertion stops a debug build, and
    /// the log records the defect in a release build. The object stays
    /// unchanged.
    func recordKindMismatch() {
        assertionFailure("an engine entry of another kind was given to \(Self.self)")
        Logger(label: ACPClientTelemetry.logLabel).error(
            "A transcript entry received an engine entry of another kind; the entry stays unchanged.",
            metadata: ["transcript.entry.class": "\(Self.self)"]
        )
    }
}

/// The members that the user-message, agent-message, and thought objects
/// share, so that one copy of the message update serves all three.
@MainActor
protocol MessageTranscriptEntry: ObservableTranscriptEntry {
    /// The content of the message.
    var content: [ContentBlock] { get set }

    /// The identifier of the message, or `nil` while no agent gave one.
    var messageId: MessageId? { get set }

    /// The `_meta` field of the message.
    var meta: JSONValue? { get set }

    /// Gives the message of an engine entry kind when the kind is the kind of
    /// this class.
    ///
    /// This case matcher is the only part of the message update that differs
    /// between the three classes.
    ///
    /// - Parameter kind: The kind of an engine entry.
    /// - Returns: The merged message, or `nil` for a kind of another class.
    static func message(in kind: FoundationModelsACP.SessionEntry.Kind) -> FoundationModelsACP.SessionEntry.Message?
}

extension MessageTranscriptEntry {
    /// Copies the merged state of the engine entry, and writes only the
    /// fields that changed. The identity, and the send state of a user
    /// message, do not change.
    ///
    /// - Parameter entry: The engine entry of this message.
    func update(from entry: FoundationModelsACP.SessionEntry) {
        guard let message = Self.message(in: entry.kind) else {
            recordKindMismatch()
            return
        }
        assign(message.content, to: \.content)
        assign(Optional(message.messageId), to: \.messageId)
        assign(message.meta.currentValue, to: \.meta)
    }
}

extension PatchField {
    /// The value of a field that holds a concrete value, or `nil` for a field
    /// that is unchanged or cleared.
    ///
    /// The session merge engine folds each field, so on a merged value
    /// `.unchanged` means that no update gave the field, and `.cleared` means
    /// that the agent cleared it. A view shows both as no value.
    var currentValue: Wrapped? {
        switch self {
        case .value(let wrapped): wrapped
        case .unchanged, .cleared: nil
        }
    }
}
