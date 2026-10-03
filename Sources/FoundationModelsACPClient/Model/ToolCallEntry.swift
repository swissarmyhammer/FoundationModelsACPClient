import Foundation
import FoundationModelsACP
import Observation

/// A tool call, as an observable transcript entry.
///
/// Each field holds the merged value of all updates for the tool call. A
/// field that no update gave, or that the agent cleared, is `nil` (or empty
/// for a list).
@MainActor @Observable
public final class ToolCallEntry: ObservableTranscriptEntry {
    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The name of the tool that the agent calls.
    public internal(set) var name: String?

    /// The title of the tool call, for a person to read.
    public internal(set) var title: String?

    /// The kind of the tool call.
    public internal(set) var kind: ToolKind?

    /// The status of the tool call.
    public internal(set) var status: ToolCallStatus?

    /// The content that the tool call made.
    public internal(set) var content: [ToolCallContent] = []

    /// The file locations that the tool call touches.
    public internal(set) var locations: [ToolCallLocation] = []

    /// The raw input of the tool call.
    public internal(set) var rawInput: JSONValue?

    /// The raw output of the tool call.
    public internal(set) var rawOutput: JSONValue?

    /// The `_meta` field of the tool call.
    public internal(set) var meta: JSONValue?

    /// The local identities of the pending elicitations that name this tool
    /// call, in the order they arrived.
    public internal(set) var linkedElicitationIDs: [PendingElicitation.ID] = []

    /// Makes the entry for a tool call from the wire.
    ///
    /// - Parameter entry: The engine entry of the tool call.
    init(wire entry: FoundationModelsACP.SessionEntry) {
        self.id = .wire(entry.id)
        update(from: entry)
    }

    /// Copies the merged state of the engine entry, and writes only the
    /// fields that changed. The linked elicitations do not change.
    ///
    /// - Parameter entry: The engine entry of this tool call.
    func update(from entry: FoundationModelsACP.SessionEntry) {
        guard case .toolCall(let toolCall) = entry.kind else {
            recordKindMismatch()
            return
        }
        assign(toolCall.name.currentValue, to: \.name)
        assign(toolCall.title.currentValue, to: \.title)
        assign(toolCall.kind.currentValue, to: \.kind)
        assign(toolCall.status.currentValue, to: \.status)
        assign(toolCall.content.resolved(onto: []), to: \.content)
        assign(toolCall.locations.resolved(onto: []), to: \.locations)
        assign(toolCall.rawInput.currentValue, to: \.rawInput)
        assign(toolCall.rawOutput.currentValue, to: \.rawOutput)
        assign(toolCall.meta.currentValue, to: \.meta)
    }
}
