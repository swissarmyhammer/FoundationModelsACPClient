import Foundation
import FoundationModelsACP
import Logging
import Observation

/// The observable state of one ACP session.
///
/// The model gives each `session/update` to the FoundationModelsACP
/// ``SessionMergeEngine``, and reflects the `Change` that the engine returns:
///
/// - `entryAdded` appends a new observable entry object to ``transcript``.
/// - `entryChanged` calls `update(from:)` on the object of that one entry.
///   ``transcript`` and every other object stay unchanged, so a streamed chunk
///   redraws only its own row.
/// - Each state change writes its last-value property: ``availableCommands``,
///   ``configOptions``, ``usage``, ``agentState``, or ``sessionInfo``.
///
/// The engine owns every merge rule: chunks append and whole messages replace;
/// a plan update replaces the plan and keeps its first position; terminal
/// chunks append bytes and an `output` snapshot replaces them; an unknown
/// update becomes an unknown entry with its raw JSON; and an unknown content
/// block stays raw in the content of its message. The model keeps no rule of
/// its own, so no update is dropped.
///
/// **UNSTABLE:** A `compaction_update` adds one ``CompactionEntry`` at the
/// end of the transcript, and later updates and summary chunks change only
/// that entry. A compaction changes only the model context of the agent, so
/// no earlier entry changes. A `notice` goes into ``notices`` and never into
/// ``transcript``: it is a live event, so the start of a resume and the close
/// clear the list.
///
/// The `_mcp_server_status` extension update of the agent is the one update
/// that does not go to the engine: it sets the status of one item of
/// ``mcpServers``, and it adds no transcript entry.
///
/// The model also holds the pending permission requests and the pending
/// session-scoped elicitations of the session, as ``pendingPermissions`` and
/// ``pendingElicitations``.
///
/// `agent_message_chunk` and `agent_thought_chunk` arrive at token rate. The
/// model collects them in a buffer and folds the buffer on a display-rate
/// cadence, so the entry of a streamed message changes one time for each
/// flush and not one time for each chunk. Any other update flushes the buffer
/// first, so the applied order is the arrival order. ``updateTap()`` gives
/// each raw update at its arrival, with no delay from the buffer.
///
/// ``prompt(_:meta:)`` shows the prompt at once as a local user message in
/// the pending state. The prompt response or the echoed `user_message`,
/// whichever arrives first, links that entry to the message id that the
/// agent gave. The entry keeps its object and its identity, and the echo
/// adds no second entry.
///
/// The connection model attaches the update subscription of the session,
/// runs the replay of a `session/resume` request, and closes the model; the
/// UI only reads ``hasMissedUpdates``, ``isReplaying``, ``history``, and
/// ``isClosed``.
@MainActor @Observable
public final class SessionModel {
    /// The identifier of the session.
    public let sessionId: SessionId

    /// The working directory of the session: the `cwd` of the last
    /// successful `session/new` or `session/resume` request. `nil` means
    /// only that no such request set it, for example in a model that a unit
    /// test makes directly.
    ///
    /// Keep this value, ``sessionId``, and ``additionalDirectories`` to
    /// resume the session later:
    ///
    /// ```swift
    /// let request = ResumeSessionRequest(
    ///     cwd: session.cwd!,
    ///     sessionId: session.sessionId,
    ///     additionalDirectories: session.additionalDirectories
    /// )
    /// ```
    ///
    /// The `cwd` of a `session/resume` request must be the `cwd` of the
    /// session, and the agent refuses another `cwd`. The resume request must
    /// also send the full list of additional directories again: an omitted
    /// or empty list activates no additional root.
    public internal(set) var cwd: AbsolutePath?

    /// The additional workspace roots of the session: the
    /// `additionalDirectories` of the last successful `session/new` or
    /// `session/resume` request, in request order. An empty list means that
    /// the session has no additional root. See ``cwd`` for the resume
    /// contract.
    public internal(set) var additionalDirectories: [AbsolutePath] = []

    /// The transcript, in the order of first appearance. An entry keeps its
    /// object and its position for the life of the model.
    public private(set) var transcript: [TranscriptEntry] = []

    /// The commands that the agent advertises. `nil` means that the agent did
    /// not report commands; an empty list means that the agent has none.
    public private(set) var availableCommands: [AvailableCommand]?

    /// The configuration options of the session. `nil` means that the agent
    /// did not report options.
    public private(set) var configOptions: [SessionConfigOption]?

    /// The last usage report, or `nil` when the agent did not report usage.
    public private(set) var usage: UsageUpdate?

    /// The last state of the foreground work of the agent: running, idle with
    /// its stop reason, or blocked on user action. `nil` means that the agent
    /// did not report a state. A stop reason that this schema revision does
    /// not know stays raw in `StopReason.unknown`.
    public private(set) var agentState: StateUpdate?

    /// The session information, folded as a patch. A field that no update
    /// gave stays `.unchanged`.
    public private(set) var sessionInfo = SessionInfoUpdate()

    /// **UNSTABLE** The notices that the agent sent for the user and that
    /// the user did not dismiss, in arrival order. A notice is transient: it
    /// is never in ``transcript``, no replay gives it again, and the start of
    /// a resume and the close clear the list.
    public private(set) var notices: [SessionNotice] = []

    /// The MCP servers of the session, each with its last status. The list
    /// holds one ``MCPServerOrigin/client`` item for each HTTP or stdio server
    /// of the `session/new` or `session/resume` request, in request order.
    /// A `session/resume` request replaces the list, and each item starts
    /// again at ``MCPServerStatus/notReported``.
    ///
    /// Each `_mcp_server_status` update of the agent sets the status of the
    /// item with its name. An update for a name that the list does not hold
    /// appends one ``MCPServerOrigin/config`` item: the configuration of the
    /// agent gave that server. These updates add no transcript entry.
    public internal(set) var mcpServers: [MCPServerItem] = []

    /// Whether the connection discarded updates of this session before the
    /// model subscribed. When this value is `true`, the transcript can lack
    /// updates. A successful replay from the start of the retained history
    /// clears it.
    public internal(set) var hasMissedUpdates = false

    /// The source of the transcript: live updates only, or a replay of the
    /// retained history before them.
    public internal(set) var history: SessionHistory = .live

    /// Whether the session is closed. A closed model changes no more.
    public internal(set) var isClosed = false

    /// The replay of a `session/resume` request, while it runs.
    var replayPhase: ReplayPhase = .idle

    /// The `session/resume` requests of the running replay, and the markers
    /// that came before the start of their request.
    @ObservationIgnored var replayRequests = ReplayRequests()

    /// The callers that wait for the end of the running replay. The end of
    /// the replay resumes each one.
    @ObservationIgnored var replayEndWaiters: [CheckedContinuation<Void, Never>] = []

    /// The task that folds the updates of the attached subscription, or `nil`
    /// when no subscription is attached.
    @ObservationIgnored var streamTask: Task<Void, Never>?

    /// The merge engine that holds the merge rules and the merged state.
    @ObservationIgnored private var engine = SessionMergeEngine()

    /// The object of each wire entry, keyed by its engine identity.
    ///
    /// The model finds the object of a changed entry by identity and not by
    /// the engine index, because the transcript can also hold entries that the
    /// client makes itself.
    @ObservationIgnored private(set) var wireEntries: [FoundationModelsACP.SessionEntry.ID: TranscriptEntry] = [:]

    /// The pending permission requests and the continuation of each one.
    /// The queue is observable, so a read of ``pendingPermissions`` tracks it.
    @ObservationIgnored let permissions = PendingRequestQueue<PendingPermissionRequest, RequestPermissionResponse>(
        cancelledResponse: PendingPermissionRequest.cancelledResponse
    )

    /// The pending session-scoped elicitations and the continuation of each
    /// one. The queue is observable, so a read of ``pendingElicitations``
    /// tracks it.
    @ObservationIgnored let elicitations = PendingRequestQueue<PendingElicitation, CreateElicitationResponse>(
        cancelledResponse: ElicitationResponseWire.cancelResponse
    )

    /// The ids of the pending elicitations that name a tool call with no
    /// transcript entry yet, keyed by that tool call. The entry takes the ids
    /// when the agent adds the tool call.
    @ObservationIgnored var unresolvedElicitationLinks: [ToolCallId: [PendingElicitation.ID]] = [:]

    /// The cadence between coalesced flushes. `.zero` applies each chunk at
    /// once.
    @ObservationIgnored private let coalescingCadence: Duration

    /// The clock that schedules the coalesced flushes.
    @ObservationIgnored private let clock: any Clock<Duration>

    /// Gives the time on ``clock`` from the creation of the model to the
    /// call. A notice records it as its arrival time.
    @ObservationIgnored private let elapsedTime: @Sendable () -> Duration

    /// The chunk buffer. A buffered chunk causes no observation; the flush
    /// folds the whole buffer through ``fold(_:)``, and each other update
    /// folds at once. Each closure holds the model weakly, so the coalescer
    /// does not keep the model alive.
    @ObservationIgnored private(set) lazy var coalescer = ChunkCoalescer(
        cadence: coalescingCadence,
        clock: clock,
        foldChunks: { [weak self] chunks in self?.fold(chunks) },
        applyUpdate: { [weak self] update in self?.fold([update]) }
    )

    /// The continuation of each open ``updateTap()`` stream, keyed by a local
    /// identity of the tap.
    @ObservationIgnored var updateTaps: [UUID: AsyncStream<SessionUpdate>.Continuation] = [:]

    /// The sender of the requests of this session.
    @ObservationIgnored let requestSender: any SessionRequestSender

    /// The W3C trace context of the last `session/prompt` that this model
    /// sent, as a `_meta` value that holds only the `traceparent` and
    /// `tracestate` members. It is `nil` before the first prompt, and when
    /// the last prompt went out with no trace context.
    ///
    /// The model records it when the request goes out, before the agent
    /// answers. Give it as the `meta` of ``cancel(meta:)``, so that the
    /// `session/cancel` span of the turn is a child of the prompt span.
    @ObservationIgnored public internal(set) var promptTraceMeta: JSONValue?

    /// Receives the session id and the new ``sessionInfo`` each time a
    /// `session_info_update` changes it, or `nil` when no one listens. The
    /// connection model sets it, so its session list shows the change.
    @ObservationIgnored var sessionInfoDidChange: ((SessionId, SessionInfoUpdate) -> Void)?

    /// Links each local prompt to the user message that the agent inserts
    /// for it, from the prompt response and from the echoed `user_message`.
    @ObservationIgnored private var promptCorrelator = PendingPromptCorrelator<TranscriptEntry.ID>()

    /// The local user messages that the agent did not link yet, keyed by
    /// their local identity.
    @ObservationIgnored private var unlinkedPrompts: [TranscriptEntry.ID: UserMessageEntry] = [:]

    /// The engine identities of the user-message echoes that arrived while a
    /// prompt waited for its response. The transcript does not show them
    /// until a response links one to its local entry, or until no prompt
    /// waits.
    @ObservationIgnored private var heldEchoes: Set<FoundationModelsACP.SessionEntry.ID> = []

    /// Makes the model of a session with an empty transcript and no state.
    ///
    /// - Parameters:
    ///   - sessionId: The identifier of the session.
    ///   - requestSender: The sender of the requests of this session. The
    ///     connection model gives the real sender; tests give a fake.
    ///   - coalescingCadence: The cadence between coalesced flushes of the
    ///     chunk buffer. `.zero` applies each chunk at once.
    ///   - clock: The clock that schedules the coalesced flushes and gives
    ///     the arrival time of each notice. Tests give a manual clock, so
    ///     they do not read the wall clock.
    init(
        sessionId: SessionId,
        requestSender: any SessionRequestSender,
        coalescingCadence: Duration = SessionModel.defaultCoalescingCadence,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sessionId = sessionId
        self.requestSender = requestSender
        self.coalescingCadence = coalescingCadence
        self.clock = clock
        self.elapsedTime = Self.makeElapsedTime(on: clock)
    }

    /// Makes a function that gives the time on a clock from now to the call.
    ///
    /// The generic parameter opens the existential clock, so the function
    /// can subtract two instants of the same clock type.
    ///
    /// - Parameter clock: The clock to read.
    /// - Returns: The function that gives the elapsed time.
    private static func makeElapsedTime<SomeClock: Clock<Duration>>(on clock: SomeClock) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    deinit {
        // A released model must not leave a tap consumer suspended, or a
        // stream task that waits on the subscription. The coalescer cancels
        // its own scheduled flush when it is released.
        streamTask?.cancel()
        for tap in updateTaps.values {
            tap.finish()
        }
    }

    /// Receives one `session/update`.
    ///
    /// Each ``updateTap()`` stream gets the update at once. The update then
    /// goes to the shared ``ChunkCoalescer``: a coalescible chunk goes into
    /// the buffer, which flushes on the cadence, and any other update flushes
    /// the buffer first and then folds, so the applied order is the arrival
    /// order. A closed model ignores the update.
    ///
    /// - Parameter update: The update to receive.
    func apply(_ update: SessionUpdate) {
        guard !isClosed else { return }
        yieldToUpdateTaps(update)
        coalescer.receive(update)
    }

    /// Folds updates into the model through the engine.
    ///
    /// The model reflects one change for each entry that the updates change,
    /// with the last state of that entry. Thus N chunks of one message write
    /// the entry one time, and the result is the same as N separate folds.
    ///
    /// Each update also goes to the prompt correlator before the engine
    /// applies it. A buffered chunk and an update that folds at once both
    /// come through here, so an echo of a local prompt links its local entry
    /// on each path.
    ///
    /// An `_mcp_server_status` update never goes to the engine, because the
    /// engine makes an unknown transcript entry from it. A valid one changes
    /// ``mcpServers``, and an update that ``MCPServerStatusUpdate`` ignores
    /// changes nothing.
    ///
    /// - Parameter updates: The updates to fold, in arrival order.
    func fold(_ updates: [SessionUpdate]) {
        let changes = updates.compactMap(engineChange(folding:))
        for change in SessionMergeEngine.Change.collapsed(changes) {
            reflect(change)
        }
    }

    /// Folds one update, and gives the change of the engine.
    ///
    /// An `_mcp_server_status` update goes to ``applyMCPServerStatus(_:)``
    /// and not to the engine, so it gives no change. Each other update goes
    /// to the prompt correlator and then to the engine.
    ///
    /// - Parameter update: The update to fold.
    /// - Returns: The change of the engine, or `nil` for an
    ///   `_mcp_server_status` update.
    private func engineChange(folding update: SessionUpdate) -> SessionMergeEngine.Change? {
        guard !MCPServerStatusUpdate.isStatusUpdate(update) else {
            if let status = MCPServerStatusUpdate.decode(update) {
                applyMCPServerStatus(status)
            }
            return nil
        }
        if let link = promptCorrelator.observe(update) {
            linkPrompt(link)
        }
        return engine.apply(update)
    }

    /// Sets the commands and the configuration options that a `session/new`
    /// or `session/resume` response gives.
    ///
    /// The engine applies its response rule: a `nil` or empty command list
    /// leaves ``availableCommands`` as it is, and a `nil` option list leaves
    /// ``configOptions`` as it is.
    ///
    /// - Parameters:
    ///   - commands: The `availableCommands` field of the response.
    ///   - options: The `configOptions` field of the response.
    func seed(availableCommands commands: [AvailableCommand]?, configOptions options: [SessionConfigOption]?) {
        let response = NewSessionResponse(sessionId: sessionId, availableCommands: commands, configOptions: options)
        for change in engine.seed(from: response) {
            reflect(change)
        }
    }

    /// Replaces ``mcpServers`` with the servers that the client sends in a
    /// `session/new` or `session/resume` request.
    ///
    /// Each HTTP or stdio server gives one ``MCPServerOrigin/client`` item,
    /// in request order, with the status ``MCPServerStatus/notReported``. A
    /// server with a transport that this schema revision does not know gives
    /// no item.
    ///
    /// - Parameter servers: The `mcpServers` field of the request.
    func setMCPServers(_ servers: [MCPServer]) {
        mcpServers = servers.compactMap(MCPServerItem.init(clientServer:))
    }

    /// Replaces ``cwd`` and ``additionalDirectories`` with the values of a
    /// `session/new` or `session/resume` request that the agent accepted.
    ///
    /// An omitted list gives an empty list, because the agent then activates
    /// no additional root.
    ///
    /// - Parameter request: The request that the agent accepted.
    func setWorkspace(of request: some SessionWorkspaceRequest) {
        cwd = request.cwd
        additionalDirectories = request.additionalDirectories ?? []
    }

    /// Applies one `_mcp_server_status` update of the agent to
    /// ``mcpServers``.
    ///
    /// The update replaces the status of the item with its name, and no other
    /// item changes. When no item has that name, the update appends a new
    /// item with the name, the transport, the origin and the status of the
    /// update, and with no configuration: the configuration of the agent gave
    /// that server, and the client did not send it.
    ///
    /// - Parameter update: The decoded status update.
    func applyMCPServerStatus(_ update: MCPServerStatusUpdate) {
        guard let item = mcpServers.first(where: { $0.name == update.name }) else {
            mcpServers.append(MCPServerItem(statusUpdate: update))
            return
        }
        item.status = update.status
    }

    /// Clears the transcript and the last-value state, so a replay of the
    /// whole history does not append its chunks to the text it already gave.
    ///
    /// The engine forgets each entry, and each replayed entry gets a new
    /// object. The local prompts lose their link state. A pending elicitation
    /// keeps its tool-call link: the link waits for the replayed entry of its
    /// tool call.
    func resetTranscript() {
        detachElicitationLinksFromToolCalls()
        engine.reset()
        transcript.removeAll()
        wireEntries.removeAll()
        heldEchoes.removeAll()
        unlinkedPrompts.removeAll()
        promptCorrelator = PendingPromptCorrelator()
        availableCommands = nil
        configOptions = nil
        usage = nil
        agentState = nil
        sessionInfo = SessionInfoUpdate()
    }

    /// Writes one engine change into the model.
    ///
    /// - Parameter change: The change that the engine returned.
    private func reflect(_ change: SessionMergeEngine.Change) {
        switch change {
        case .entryAdded(_, let entry): addEntry(entry)
        case .entryChanged(_, let entry): changeEntry(entry)
        case .availableCommandsChanged(let commands): availableCommands = commands
        case .configOptionsChanged(let options): configOptions = options
        case .usageChanged(let report): usage = report
        case .agentStateChanged(let state): agentState = state
        case .sessionInfoChanged(let info): changeSessionInfo(info)
        case .notice(let notice): notices.append(SessionNotice(notice: notice, arrivalTime: elapsedTime()))
        }
    }

    /// Writes the session information that the engine folded, and tells
    /// ``sessionInfoDidChange`` of the change.
    ///
    /// - Parameter info: The folded session information.
    private func changeSessionInfo(_ info: SessionInfoUpdate) {
        sessionInfo = info
        sessionInfoDidChange?(sessionId, info)
    }

    /// Shows a new engine entry in the transcript.
    ///
    /// An entry that a prompt link already gave a local object updates that
    /// object, so the echo of a prompt adds no second entry. A user-message
    /// echo that arrives while a prompt waits for its response is held: the
    /// response tells whether it belongs to that prompt. Each other entry
    /// gets a new object.
    ///
    /// - Parameter entry: The engine entry that the engine added.
    private func addEntry(_ entry: FoundationModelsACP.SessionEntry) {
        if let linked = wireEntries[entry.id] {
            linked.update(from: entry)
            return
        }
        if case .userMessage = entry.kind, isPromptAwaitingResponse {
            heldEchoes.insert(entry.id)
            return
        }
        appendWireEntry(entry)
    }

    /// Appends a new object for an engine entry to the transcript.
    ///
    /// A new tool-call entry also takes the links of the pending
    /// elicitations that arrived before it.
    ///
    /// - Parameter entry: The engine entry.
    private func appendWireEntry(_ entry: FoundationModelsACP.SessionEntry) {
        let object = TranscriptEntry(wire: entry)
        wireEntries[entry.id] = object
        attachUnresolvedElicitationLinks(to: object)
        transcript.append(object)
    }

    /// Copies the merged state of a changed engine entry into its object.
    ///
    /// A held echo has no object yet; the engine keeps its merged state, and
    /// the link or the release reads that state. The engine changes only an
    /// entry that it added before, so each other object is always there. A
    /// missing object is a defect: the assertion stops a debug build, the log
    /// records it in a release build, and the model stays unchanged.
    ///
    /// - Parameter entry: The engine entry that the engine changed.
    private func changeEntry(_ entry: FoundationModelsACP.SessionEntry) {
        guard !heldEchoes.contains(entry.id) else { return }
        guard let object = wireEntries[entry.id] else {
            recordDefect(
                "the engine changed an entry that the model does not have: \(entry.id)",
                log: "The merge engine changed a transcript entry that the session model does not have; the model stays unchanged."
            )
            return
        }
        object.update(from: entry)
    }

    /// Records a defect of the model: the assertion stops a debug build, and
    /// the log records the defect in a release build.
    ///
    /// - Parameters:
    ///   - detail: The assertion message, for the developer.
    ///   - message: The log message, for a release build.
    private func recordDefect(_ detail: String, log message: Logger.Message) {
        assertionFailure(detail)
        Logger(label: ACPClientTelemetry.logLabel).error(
            message,
            metadata: [ACPClientTelemetry.LogMetadataKey.sessionID: "\(sessionId.rawValue)"]
        )
    }

    // MARK: - Notices

    /// Removes one notice from ``notices``, for example when the user closes
    /// it. A call with an unknown or already dismissed id changes nothing.
    ///
    /// - Parameter id: The id of the notice.
    public func dismissNotice(_ id: SessionNotice.ID) {
        notices.removeAll { $0.id == id }
    }

    /// Removes each notice. A notice is a live event of one connection, so
    /// the start of a resume and the close call this.
    func clearNotices() {
        notices.removeAll()
    }

    // MARK: - Prompt links

    /// Tells whether a local prompt waits for its `session/prompt` response.
    private var isPromptAwaitingResponse: Bool {
        unlinkedPrompts.values.contains { $0.sendState == .pending }
    }

    /// Appends the local user message of a prompt that the client is about
    /// to send, and records it for the link.
    ///
    /// - Parameter entry: The local user message, in the pending state.
    func addPendingPrompt(_ entry: UserMessageEntry) {
        unlinkedPrompts[entry.id] = entry
        promptCorrelator.addPendingPrompt(entry.id)
        transcript.append(.userMessage(entry))
    }

    /// Records the `session/prompt` response of a local prompt.
    ///
    /// The response sets the message id and the sent state at once. When the
    /// echo arrived first, the response also links the held echo to the local
    /// entry. When no other prompt waits, each held echo that no response
    /// claimed is a message from another source, so the transcript shows it.
    ///
    /// - Parameters:
    ///   - entry: The local user message of the prompt.
    ///   - response: The response, which names the inserted user message.
    func resolvePrompt(_ entry: UserMessageEntry, with response: PromptResponse) {
        entry.assign(Optional(response.messageId), to: \.messageId)
        entry.assign(.sent, to: \.sendState)
        if let link = promptCorrelator.resolve(entry.id, with: response) {
            linkPrompt(link)
        }
        showUnclaimedEchoesWhenNoPromptWaits()
    }

    /// Records the failure of a local prompt: the entry gets the failed
    /// state and no link.
    ///
    /// - Parameter entry: The local user message of the prompt.
    func failPrompt(_ entry: UserMessageEntry) {
        unlinkedPrompts[entry.id] = nil
        promptCorrelator.removePendingPrompt(entry.id)
        entry.assign(.failed, to: \.sendState)
        showUnclaimedEchoesWhenNoPromptWaits()
    }

    /// Appends an entry that the client made itself to the transcript.
    ///
    /// - Parameter entry: The local entry.
    func appendLocalEntry(_ entry: TranscriptEntry) {
        transcript.append(entry)
    }

    /// Makes the local entry of a prompt the object of its engine entry.
    ///
    /// The local entry keeps its object and its identity. It takes the
    /// message id and the sent state, and, when its echo was held, the merged
    /// state of that echo. The correlator links only a prompt that the model
    /// recorded and did not link, so a missing prompt is a defect: the
    /// assertion stops a debug build, the log records it in a release build,
    /// and the model stays unchanged.
    ///
    /// - Parameter link: The link that the correlator gave.
    private func linkPrompt(_ link: PendingPromptCorrelator<TranscriptEntry.ID>.Link) {
        guard let entry = unlinkedPrompts.removeValue(forKey: link.localID) else {
            recordDefect(
                "the correlator linked a prompt that the model does not have: \(link.localID)",
                log: "The prompt correlator linked a prompt that the session model does not have; the model stays unchanged."
            )
            return
        }
        wireEntries[link.entryID] = .userMessage(entry)
        entry.assign(Optional(link.messageId), to: \.messageId)
        entry.assign(.sent, to: \.sendState)
        guard heldEchoes.remove(link.entryID) != nil, let echo = engine.entry(withID: link.entryID) else { return }
        entry.update(from: echo)
    }

    /// Shows each held echo, in engine order, when no prompt waits for its
    /// response. No later response can claim such an echo.
    private func showUnclaimedEchoesWhenNoPromptWaits() {
        guard !isPromptAwaitingResponse, !heldEchoes.isEmpty else { return }
        let unclaimed = heldEchoes
        heldEchoes.removeAll()
        for entry in engine.entries where unclaimed.contains(entry.id) {
            appendWireEntry(entry)
        }
    }
}
