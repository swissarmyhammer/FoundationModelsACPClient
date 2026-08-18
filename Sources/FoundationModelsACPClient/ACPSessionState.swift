import Foundation
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
/// The agent's record is not monotonic: compaction rewrites it, and entries
/// that this container showed can stop to exist. ``beginRehydration()``,
/// ``endRehydration()``, and ``cancelRehydration()`` rebuild this projection
/// from a `session/resume` replay. ACP defines no history-invalidation signal
/// at this time, so the host must start that reload itself; until a reload,
/// the projection can be stale after compaction.
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

    /// The permission requests that wait for the user's answer, in arrival
    /// order.
    ///
    /// This is the concurrency policy: the container supports more than one
    /// outstanding request at the same time. Each request keeps its position
    /// until it resolves, and each request resolves independently of the
    /// others. Resolve one request with
    /// ``answerPermissionRequest(_:with:)`` or with
    /// ``cancelPermissionRequest(_:)``.
    public private(set) var pendingPermissionRequests: [PendingPermissionRequest] = []

    /// The accumulated per-identity state, folded with the wire package's
    /// own upsert rules.
    private var aggregator = SessionUpdateAggregator()

    /// The identities that already have an entry in ``entries``.
    private var knownEntryIdentities: Set<SessionEntry.ID> = []

    /// The default coalescing cadence, in milliseconds.
    private static let defaultCoalescingCadenceMilliseconds = 33

    /// The default display-rate cadence for chunk coalescing.
    ///
    /// The value gives approximately 30 flushes for each second. That rate is
    /// smooth for a reader and far under the token rate.
    public static let defaultCoalescingCadence: Duration =
        .milliseconds(defaultCoalescingCadenceMilliseconds)

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
    /// While a rehydration capture is active, the update goes into the
    /// capture buffer instead, and ``endRehydration()`` rebuilds the state
    /// from that buffer.
    ///
    /// A coalescible chunk lands in the buffer, and the buffer flushes on the
    /// cadence. Any other update flushes the buffer first and then applies,
    /// so the applied order stays equal to plain one-by-one application.
    ///
    /// - Parameter update: The update to apply.
    public func apply(_ update: SessionUpdate) {
        if isRehydrating {
            rehydrationReplay.append(update)
            return
        }
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

    /// Tells whether a rehydration capture is active.
    ///
    /// ``beginRehydration()`` sets it, and ``endRehydration()`` or
    /// ``cancelRehydration()`` clears it. A UI can bind to it to show a
    /// reload indicator.
    public private(set) var isRehydrating = false

    /// The captured replay of an active rehydration. The buffer is not
    /// observable, so a capture causes no invalidation.
    @ObservationIgnored private var rehydrationReplay: [SessionUpdate] = []

    /// Starts a rehydration capture.
    ///
    /// The agent's record is not monotonic: compaction rewrites it, and
    /// entries that this container showed can stop to exist. A rebuild from
    /// a `session/resume` replay is the correction. Call this before the
    /// `session/resume` call. Each update that ``apply(_:)`` then receives
    /// goes into a capture buffer and does not touch the observable state.
    /// Call ``endRehydration()`` after the `session/resume` response, or
    /// ``cancelRehydration()`` when the call fails.
    ///
    /// The call flushes the coalescing buffer first, so the prior state is
    /// complete while the capture is active.
    public func beginRehydration() {
        flushPendingChunks()
        rehydrationReplay.removeAll()
        isRehydrating = true
    }

    /// Ends the rehydration capture and rebuilds the state from it.
    ///
    /// The rebuild discards the accumulated record projection and applies
    /// the captured replay through the same code path as a live stream.
    /// Thus a container that loads mid-session reaches the same state as a
    /// container that streamed from the start, and a second reload with the
    /// same replay changes nothing.
    ///
    /// The whole rebuild is one synchronous main-actor pass, so a UI never
    /// renders the empty intermediate state. Pending permission requests
    /// are live request state, not record state; they stay pending and
    /// their continuations stay held.
    ///
    /// A call with no active capture changes nothing.
    public func endRehydration() {
        guard isRehydrating else { return }
        isRehydrating = false
        let replay = rehydrationReplay
        rehydrationReplay.removeAll()
        resetRecordProjection()
        for update in replay {
            applyUnbuffered(update)
        }
    }

    /// Discards the rehydration capture and keeps the prior state.
    ///
    /// The host calls this when the `session/resume` call fails, so a
    /// partial replay never becomes the state. The prior state stays as it
    /// was: possibly stale, but consistent. A call with no active capture
    /// changes nothing.
    public func cancelRehydration() {
        guard isRehydrating else { return }
        isRehydrating = false
        rehydrationReplay.removeAll()
    }

    /// Clears every field that the record projects into, back to the value
    /// an empty session state holds.
    ///
    /// ``pendingPermissionRequests`` and its continuations stay untouched:
    /// they are live request state, not record state.
    private func resetRecordProjection() {
        aggregator = SessionUpdateAggregator()
        entries = []
        knownEntryIdentities = []
        inFlightAgentMessageID = nil
        inFlightThoughtID = nil
        availableCommands = []
        configOptions = []
        title = nil
        updatedAt = nil
        usage = nil
        turnState = .idle
        lastStopReason = nil
    }

    /// The lifecycle state of one permission request between arrival and
    /// resolution.
    ///
    /// The three cases are mutually exclusive. A resolved request has no
    /// entry at all, so no state and no continuation outlives a request.
    private enum PermissionRequestState {
        /// The request arrived. Its continuation is not registered yet.
        case awaitingRegistration

        /// A cancellation arrived before the continuation registered. The
        /// registration reads this case and answers `cancelled` at once,
        /// so the continuation never suspends.
        case cancelledBeforeRegistration

        /// The agent's call is suspended on this continuation.
        case suspended(CheckedContinuation<RequestPermissionResponse, Never>)
    }

    /// The lifecycle state of each unresolved permission request, keyed by
    /// the request id. The storage is not observable; the UI binds to
    /// ``pendingPermissionRequests`` instead.
    @ObservationIgnored private var permissionRequestStates: [UUID: PermissionRequestState] = [:]

    /// Suspends until the user answers or cancels the permission request.
    ///
    /// The call adds one entry to ``pendingPermissionRequests`` and holds
    /// the continuation until one of these resolutions arrives:
    ///
    /// - ``answerPermissionRequest(_:with:)`` resolves it with the
    ///   selected option.
    /// - ``cancelPermissionRequest(_:)`` and
    ///   ``cancelAllPermissionRequests()`` resolve it with `cancelled`.
    /// - Cancellation of the surrounding task resolves it with
    ///   `cancelled`. The connection cancels that task when the agent
    ///   withdraws the request, when the turn gets cancelled, or when the
    ///   transport closes.
    ///
    /// Each resolution removes the pending entry and resumes the
    /// continuation exactly one time, so no continuation leaks and no
    /// ghost prompt stays on screen.
    ///
    /// - Parameter request: The permission request from the agent.
    /// - Returns: The user's decision, or the `cancelled` outcome.
    public func awaitPermissionDecision(
        for request: RequestPermissionRequest
    ) async -> RequestPermissionResponse {
        let id = UUID()
        permissionRequestStates[id] = .awaitingRegistration
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if case .cancelledBeforeRegistration = permissionRequestStates[id] {
                    permissionRequestStates[id] = nil
                    continuation.resume(returning: RequestPermissionResponse(outcome: .cancelled))
                } else {
                    pendingPermissionRequests.append(
                        PendingPermissionRequest(id: id, request: request)
                    )
                    permissionRequestStates[id] = .suspended(continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPermissionRequest(id)
            }
        }
    }

    /// Answers one pending permission request with the selected option.
    ///
    /// The call removes the pending entry and resolves the agent's
    /// in-flight request. A call with an unknown or already resolved id
    /// changes nothing.
    ///
    /// - Parameters:
    ///   - id: The id of the pending request.
    ///   - optionId: The id of the selected option. Give the id of one
    ///     option of the request.
    public func answerPermissionRequest(_ id: UUID, with optionId: PermissionOptionId) {
        resolvePermissionRequest(
            id: id,
            outcome: .selected(SelectedPermissionOutcome(optionId: optionId))
        )
    }

    /// Cancels one permission request.
    ///
    /// The call removes the pending entry and resolves the agent's
    /// in-flight request with the `cancelled` outcome, which is the spec's
    /// outcome for a request the user did not decide. A call with an
    /// unknown or already resolved id changes nothing.
    ///
    /// - Parameter id: The id of the request.
    public func cancelPermissionRequest(_ id: UUID) {
        switch permissionRequestStates[id] {
        case .suspended:
            resolvePermissionRequest(id: id, outcome: .cancelled)
        case .awaitingRegistration:
            permissionRequestStates[id] = .cancelledBeforeRegistration
        case .cancelledBeforeRegistration, nil:
            // The request is already cancelled or already resolved.
            break
        }
    }

    /// Cancels every pending permission request.
    ///
    /// The host calls this on connection close, so a dropped connection
    /// leaves no pending prompt and leaks no continuation.
    public func cancelAllPermissionRequests() {
        for id in pendingPermissionRequests.map(\.id) {
            cancelPermissionRequest(id)
        }
    }

    /// Removes one pending permission request and resumes its suspended
    /// continuation with the outcome.
    ///
    /// A request whose continuation is not suspended stays unchanged, so
    /// no continuation can resume two times.
    ///
    /// - Parameters:
    ///   - id: The id of the request.
    ///   - outcome: The outcome to answer with.
    private func resolvePermissionRequest(id: UUID, outcome: RequestPermissionOutcome) {
        guard case .suspended(let continuation) = permissionRequestStates[id] else { return }
        permissionRequestStates[id] = nil
        pendingPermissionRequests.removeAll { $0.id == id }
        continuation.resume(returning: RequestPermissionResponse(outcome: outcome))
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
