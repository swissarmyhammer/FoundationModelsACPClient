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

    /// The start time and the end time of the tool call. The tool call ends
    /// when its status first becomes `completed`, `failed`, or `cancelled`.
    /// See ``EntryTiming``.
    public let timing = EntryTiming()

    /// The ACP id of the tool call, as the agent sent it. It never changes.
    public nonisolated let toolCallId: ToolCallId

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

    /// The completion token of the background run of this tool call, from
    /// `_meta.sah.backgroundRun.completionToken`, or `nil` when the call is
    /// not a background run.
    ///
    /// The agent keeps a background call `in_progress` with this marker
    /// until the work really ends. Then it sends the final status on the same
    /// tool call id. Thus a call with a token and no final status is still
    /// busy: the return of the start of the work is not the end of the call.
    /// The value follows ``meta``, so it is observable.
    public var backgroundRun: String? {
        guard case .object(let members)? = meta,
              case .object(let sah)? = members[SAH.metaKey],
              case .object(let run)? = sah[Self.backgroundRunKey],
              case .string(let token)? = run[Self.completionTokenKey]
        else { return nil }
        return token
    }

    /// The `_meta.sah` member name of the background run marker.
    private static let backgroundRunKey = "backgroundRun"

    /// The member name of the completion token in the background run marker.
    private static let completionTokenKey = "completionToken"

    /// The session that holds this entry in its transcript, or `nil` for an
    /// entry that no session holds. It does not change after the session
    /// appends the entry.
    @ObservationIgnored weak var session: SessionModel?

    /// Whether the agent no longer tracks this tool call, but the call has
    /// no final status.
    ///
    /// The value is `true` for a call that has no final status when one of
    /// these conditions is true:
    ///
    /// - The session is closed, for example because the connection to the
    ///   agent ended.
    /// - The session is idle, and its ``SessionModel/background`` list does
    ///   not hold this call. An idle state with no `background` member has
    ///   no background work, so it holds no call. Then all work is done.
    ///
    /// A UI uses this value to stop the busy indicator of a call that will
    /// never get its final status. A call with a final status is never
    /// stale. An entry that no session holds is not stale. The value is
    /// observable.
    public var isStale: Bool {
        if let status, status.isFinal { return false }
        guard let session else { return false }
        if session.isClosed { return true }
        guard case .idle = session.agentState else { return false }
        let listed = session.background.contains { work in
            if case .toolCall(let call) = work { call.toolCallId == toolCallId } else { false }
        }
        return !listed
    }

    /// The child session that this tool call started, from the
    /// `_meta.sah.agentRun` link of the tool call, or `nil` when the call has
    /// no link or the child was removed. The value is observable, so a view
    /// of the agents call sees the link arrive and see it go. The parent owns
    /// its children, and the model clears the link when it removes the child.
    public internal(set) var childSession: SessionModel?

    /// Sets the child session of this tool call.
    ///
    /// - Parameter child: The child, or `nil`.
    func setChild(_ child: SessionModel?) {
        guard childSession !== child else { return }
        childSession = child
    }

    /// The local identities of the pending elicitations that name this tool
    /// call, in the order they arrived.
    public internal(set) var linkedElicitationIDs: [PendingElicitation.ID] = []

    /// Makes the entry for a tool call from the wire.
    ///
    /// - Parameters:
    ///   - entry: The engine entry of the tool call.
    ///   - toolCallId: The ACP id of the tool call, as the agent sent it.
    init(wire entry: FoundationModelsACP.SessionEntry, toolCallId: ToolCallId) {
        self.id = .wire(entry.id)
        self.toolCallId = toolCallId
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
