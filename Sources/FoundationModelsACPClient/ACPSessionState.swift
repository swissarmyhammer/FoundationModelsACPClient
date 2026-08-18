import FoundationModelsACP
import Observation

/// The turn state of one session, as the agent's `state_update` notifications
/// report it.
public enum TurnState: Hashable, Sendable {
    /// The agent is ready for a new prompt.
    case idle

    /// Foreground work is in progress.
    case running

    /// Foreground work is blocked on user action.
    case awaitingInput
}

/// The observable state of one ACP session.
///
/// This is a projection of the agent's `session/update` stream, never a
/// record: the agent's own transcript stays the source of truth. ``apply(_:)``
/// lands every `SessionUpdate` case:
///
/// - The chunk and upsert cases land in ``entries`` and in the accumulated
///   message content. Chunks append; whole-message upserts replace.
/// - `tool_call_update` and `tool_call_content_chunk` fold into
///   ``toolCalls``, keyed by `toolCallId`. An update for a known id mutates
///   in place. An update for an unknown id is adopted: the first sighting
///   creates the tool call.
/// - `state_update` drives ``turnState`` and ``lastStopReason``.
/// - `plan_update`, `available_commands_update`, `config_option_update`,
///   `session_info_update`, `usage_update`, `terminal_update`, and
///   `terminal_output_chunk` land in their own properties.
/// - An unrecognized update changes no state.
///
/// The upsert rules come from the wire package's own
/// `SessionUpdateAggregator`, so this container holds no second copy of them.
///
/// `agent_message_chunk` and `agent_thought_chunk` arrive at token rate. This
/// container does not mutate observable state for each of those chunks.
/// It collects them in a buffer and flushes the buffer on a display-rate
/// cadence, so SwiftUI sees far fewer invalidations than chunks. Any other
/// update flushes the buffer first, so the applied order, and thus the final
/// text, stays identical to plain one-by-one application. A turn end arrives
/// as `state_update`, so it flushes synchronously. ``flushPendingChunks()``
/// gives the host the same synchronous flush, for example on connection
/// close.
@MainActor
@Observable
public final class ACPSessionState {
    /// The ordered entry list, stably identified for SwiftUI `ForEach`.
    ///
    /// The list only appends. An update for a known identity mutates the
    /// content that the identity keys, and it never moves or replaces an
    /// entry.
    public private(set) var entries: [SessionEntry] = []

    /// The id of the in-flight agent message. It is the append target for
    /// `agent_message_chunk` updates.
    public private(set) var inFlightAgentMessageID: MessageId?

    /// The id of the in-flight agent thought. Thought chunks stay separate
    /// from message chunks, so a UI can address reasoning independently.
    public private(set) var inFlightThoughtID: MessageId?

    /// The commands the agent can run, replaced whole by each
    /// `available_commands_update`.
    public private(set) var availableCommands: [AvailableCommand] = []

    /// The session configuration options and their current values, replaced
    /// whole by each `config_option_update`. This is where ACP v2 reports
    /// the session's current mode.
    public private(set) var configOptions: [SessionConfigOption] = []

    /// The session title, folded from `session_info_update`.
    public private(set) var title: String?

    /// The RFC 3339 timestamp of the last activity, folded from
    /// `session_info_update`.
    public private(set) var updatedAt: String?

    /// The latest context-window and cost report.
    public private(set) var usage: UsageUpdate?

    /// The turn state, driven by `state_update`.
    public private(set) var turnState: TurnState = .idle

    /// The last stop reason an idle `state_update` reported. An idle update
    /// that omits its stop reason keeps the stored value.
    public private(set) var lastStopReason: StopReason?

    /// The accumulated per-identity state, folded with the wire package's
    /// own upsert rules.
    private var aggregator = SessionUpdateAggregator()

    /// The identities that already have an entry in ``entries``.
    private var knownEntryIdentities: Set<SessionEntry.ID> = []

    /// The default display-rate cadence for chunk coalescing.
    ///
    /// The value gives approximately 30 flushes for each second. That rate is
    /// smooth for a reader and far under the token rate.
    public static let defaultCoalescingCadence: Duration = .milliseconds(33)

    /// The cadence between coalesced flushes.
    private let coalescingCadence: Duration

    /// The clock that schedules the coalesced flushes.
    private let clock: any Clock<Duration>

    /// Creates an empty session state.
    ///
    /// - Parameters:
    ///   - coalescingCadence: The cadence between coalesced flushes.
    ///   - clock: The clock that schedules the coalesced flushes. Tests
    ///     inject a manual clock, so they do not read the wall clock.
    public init(
        coalescingCadence: Duration = ACPSessionState.defaultCoalescingCadence,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.coalescingCadence = coalescingCadence
        self.clock = clock
    }

    /// The accumulated tool calls, keyed by `toolCallId`.
    ///
    /// Each value carries the tool call's full payload: `status`, `kind`,
    /// `content`, `locations`, `rawInput`, `rawOutput`, and `title`. The
    /// status keeps ACP's full range, so `pending` (queued) stays distinct
    /// from `inProgress` (running).
    public var toolCalls: [ToolCallId: ToolCallUpdate] {
        aggregator.toolCalls
    }

    /// The plans, keyed by `planId`. Each `plan_update` replaces its plan's
    /// entries whole.
    public var plans: [PlanId: [PlanEntry]] {
        aggregator.plans
    }

    /// The agent-owned display terminals, keyed by `terminalId`.
    public var terminals: [TerminalId: AccumulatedTerminal] {
        aggregator.terminals
    }

    /// Returns the accumulated content of one message.
    ///
    /// - Parameter id: The message id.
    /// - Returns: The content blocks, or an empty array for an unknown id.
    public func messageContent(for id: MessageId) -> [ContentBlock] {
        aggregator.messages[id] ?? []
    }

    /// Folds one session update into the observable state.
    ///
    /// A coalescible chunk lands in the buffer, and the buffer flushes on the
    /// cadence. Any other update flushes the buffer first and then applies,
    /// so the applied order stays equal to plain one-by-one application.
    ///
    /// - Parameter update: The update to apply.
    public func apply(_ update: SessionUpdate) {
        if let pending = pendingChunk(for: update) {
            enqueue(pending)
            return
        }
        flushPendingChunks()
        applyUnbuffered(update)
    }

    /// Flushes the coalescing buffer into the observable state, and cancels
    /// the scheduled flush.
    ///
    /// The flush folds all buffered chunks into one local copy of the
    /// accumulated state and writes that copy back one time. The whole flush
    /// therefore causes a small, constant number of observable mutations,
    /// however many chunks the buffer holds.
    ///
    /// The host calls this on connection close, so the last partial chunk is
    /// never left buffered. An empty buffer flushes to nothing.
    public func flushPendingChunks() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard !pendingChunks.isEmpty else { return }
        let pending = pendingChunks
        pendingChunks.removeAll(keepingCapacity: true)
        var folded = aggregator
        for item in pending {
            folded.apply(item.update)
            recordChunkIdentity(kind: item.kind, messageID: item.messageID)
        }
        aggregator = folded
    }

    /// One buffered chunk update and the in-flight target it lands on.
    private struct PendingChunk {
        /// The in-flight target of the chunk.
        let kind: CoalescedChunkKind

        /// The id of the message the chunk appends to.
        let messageID: MessageId

        /// The chunk update, replayed into the aggregator at flush time.
        let update: SessionUpdate
    }

    /// The two update kinds that coalesce.
    private enum CoalescedChunkKind {
        /// An `agent_message_chunk`.
        case agentMessage

        /// An `agent_thought_chunk`.
        case agentThought
    }

    /// The buffered chunks, in arrival order. The buffer is not observable,
    /// so an append causes no invalidation.
    @ObservationIgnored private var pendingChunks: [PendingChunk] = []

    /// The task that flushes the buffer after one cadence. `nil` when no
    /// flush is scheduled.
    @ObservationIgnored private var scheduledFlush: Task<Void, Never>?

    deinit {
        scheduledFlush?.cancel()
    }

    /// Returns the buffer item for a coalescible update, or `nil` for an
    /// update this container applies immediately.
    ///
    /// Only the two token-rate chunk cases coalesce. Every other case,
    /// including a future case this package does not know, takes the
    /// immediate path. That default is the safe direction: an update that
    /// does not coalesce is never delayed and never reordered.
    ///
    /// - Parameter update: The received update.
    /// - Returns: The buffer item, or `nil`.
    private func pendingChunk(for update: SessionUpdate) -> PendingChunk? {
        switch update {
        case .agentMessageChunk(let chunk):
            PendingChunk(kind: .agentMessage, messageID: chunk.messageId, update: update)
        case .agentThoughtChunk(let chunk):
            PendingChunk(kind: .agentThought, messageID: chunk.messageId, update: update)
        default:
            nil
        }
    }

    /// Appends one item to the coalescing buffer and schedules the flush.
    ///
    /// - Parameter pending: The item to buffer.
    private func enqueue(_ pending: PendingChunk) {
        pendingChunks.append(pending)
        scheduleFlushIfNeeded()
    }

    /// Schedules one flush after the cadence, when none is scheduled.
    ///
    /// The task holds the state weakly, so a released session never keeps a
    /// timer alive. A synchronous flush cancels the task.
    private func scheduleFlushIfNeeded() {
        guard scheduledFlush == nil else { return }
        let cadence = coalescingCadence
        let clock = clock
        scheduledFlush = Task { [weak self] in
            try? await clock.sleep(for: cadence, tolerance: nil)
            guard !Task.isCancelled else { return }
            self?.completeScheduledFlush()
        }
    }

    /// Clears the scheduled-flush handle and flushes the buffer.
    private func completeScheduledFlush() {
        scheduledFlush = nil
        flushPendingChunks()
    }

    /// Records the in-flight id and the entry of one coalescible chunk.
    ///
    /// The in-flight id only mutates when it changes, so a run of chunks for
    /// one message writes it one time.
    ///
    /// - Parameters:
    ///   - kind: The in-flight target of the chunk.
    ///   - messageID: The id of the message the chunk appends to.
    private func recordChunkIdentity(kind: CoalescedChunkKind, messageID: MessageId) {
        switch kind {
        case .agentMessage:
            if inFlightAgentMessageID != messageID {
                inFlightAgentMessageID = messageID
            }
            appendEntryIfNew(.agentMessage(messageID))
        case .agentThought:
            if inFlightThoughtID != messageID {
                inFlightThoughtID = messageID
            }
            appendEntryIfNew(.agentThought(messageID))
        }
    }

    /// Folds one update into the observable state, with no buffering.
    ///
    /// This function is complete for every update case. ``apply(_:)`` routes
    /// the two coalescible chunk cases into the buffer before this switch,
    /// and the flush lands them through the same ``recordChunkIdentity``
    /// helper, so the two paths stay in agreement.
    ///
    /// - Parameter update: The update to apply.
    private func applyUnbuffered(_ update: SessionUpdate) {
        switch update {
        case .userMessageChunk(let chunk):
            appendEntryIfNew(.userMessage(chunk.messageId))
        case .userMessage(let message):
            appendEntryIfNew(.userMessage(message.messageId))
        case .agentMessageChunk(let chunk):
            recordChunkIdentity(kind: .agentMessage, messageID: chunk.messageId)
        case .agentMessage(let message):
            inFlightAgentMessageID = message.messageId
            appendEntryIfNew(.agentMessage(message.messageId))
        case .agentThoughtChunk(let chunk):
            recordChunkIdentity(kind: .agentThought, messageID: chunk.messageId)
        case .agentThought(let thought):
            inFlightThoughtID = thought.messageId
            appendEntryIfNew(.agentThought(thought.messageId))
        case .stateUpdate(let state):
            apply(state)
        case .toolCallContentChunk(let chunk):
            appendEntryIfNew(.toolCall(chunk.toolCallId))
        case .toolCallUpdate(let toolCall):
            appendEntryIfNew(.toolCall(toolCall.toolCallId))
        case .terminalUpdate, .terminalOutputChunk, .planUpdate:
            // The aggregator below holds the whole effect of these cases.
            break
        case .availableCommandsUpdate(let payload):
            availableCommands = payload.availableCommands
        case .configOptionUpdate(let payload):
            configOptions = payload.configOptions
        case .sessionInfoUpdate(let info):
            title = resolve(info.title, current: title)
            updatedAt = resolve(info.updatedAt, current: updatedAt)
        case .usageUpdate(let payload):
            usage = payload
        case .unknown:
            // An unrecognized update changes no state. The wire type keeps
            // the raw payload, so nothing is lost on re-encode.
            break
        }
        aggregator.apply(update)
    }

    /// Applies one `state_update` payload to the turn state.
    ///
    /// - Parameter state: The received state.
    private func apply(_ state: StateUpdate) {
        switch state {
        case .running:
            turnState = .running
        case .idle(let idle):
            turnState = .idle
            if let stopReason = idle.stopReason {
                lastStopReason = stopReason
            }
        case .requiresAction:
            turnState = .awaitingInput
        case .unknown:
            break
        }
    }

    /// Appends an entry when its identity is new.
    ///
    /// - Parameter entry: The candidate entry.
    private func appendEntryIfNew(_ entry: SessionEntry) {
        guard knownEntryIdentities.insert(entry.id).inserted else { return }
        entries.append(entry)
    }

    /// Resolves one patch-semantics field onto a stored optional value:
    /// omitted keeps the stored value, `null` clears it, and a concrete
    /// value replaces it.
    ///
    /// - Parameters:
    ///   - field: The received field.
    ///   - current: The stored value.
    /// - Returns: The new stored value.
    private func resolve<Value: Codable & Hashable & Sendable>(
        _ field: PatchField<Value>,
        current: Value?
    ) -> Value? {
        switch field {
        case .unchanged: current
        case .cleared: nil
        case .value(let value): value
        }
    }
}
