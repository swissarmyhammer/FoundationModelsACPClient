import FoundationModelsACP

/// The display-rate chunk buffer that ``SessionModel`` and
/// ``ACPSessionState`` share.
///
/// `agent_message_chunk` and `agent_thought_chunk` arrive at token rate. The
/// coalescer holds them in a buffer and gives the whole buffer to its owner on
/// a display-rate cadence, so the owner writes its observable state one time
/// for each flush and not one time for each chunk. Any other update flushes
/// the buffer first and then goes to the owner, so the applied order is the
/// arrival order. With a `.zero` cadence, each chunk goes to the owner at
/// once.
///
/// The owner gives two closures: one folds a batch of buffered chunks, and one
/// applies one update at once. The owner holds the coalescer, so each closure
/// must capture the owner weakly.
@MainActor
final class ChunkCoalescer {
    /// The cadence between coalesced flushes. `.zero` applies each chunk at
    /// once.
    private let cadence: Duration

    /// The clock that schedules the coalesced flushes.
    private let clock: any Clock<Duration>

    /// Folds a batch of buffered chunks into the owner, in arrival order.
    private let foldChunks: @MainActor ([SessionUpdate]) -> Void

    /// Applies one update to the owner at once.
    private let applyUpdate: @MainActor (SessionUpdate) -> Void

    /// The buffered chunks, in arrival order.
    private var pendingChunks: [SessionUpdate] = []

    /// The task that flushes the buffer after one cadence, or `nil` when no
    /// flush is scheduled.
    private var scheduledFlush: Task<Void, Never>?

    /// Makes a coalescer with an empty buffer.
    ///
    /// - Parameters:
    ///   - cadence: The cadence between coalesced flushes. `.zero` applies
    ///     each chunk at once.
    ///   - clock: The clock that schedules the coalesced flushes. Tests give
    ///     a manual clock, so they do not read the wall clock.
    ///   - foldChunks: Folds a batch of buffered chunks into the owner.
    ///   - applyUpdate: Applies one update to the owner at once.
    init(
        cadence: Duration,
        clock: any Clock<Duration>,
        foldChunks: @escaping @MainActor ([SessionUpdate]) -> Void,
        applyUpdate: @escaping @MainActor (SessionUpdate) -> Void
    ) {
        self.cadence = cadence
        self.clock = clock
        self.foldChunks = foldChunks
        self.applyUpdate = applyUpdate
    }

    deinit {
        scheduledFlush?.cancel()
    }

    /// Tells whether an update goes into the chunk buffer.
    ///
    /// Only the two token-rate chunk cases coalesce. Each other case applies
    /// at once, so it is never delayed and never reordered.
    ///
    /// - Parameter update: The received update.
    /// - Returns: `true` for `agent_message_chunk` and `agent_thought_chunk`.
    static func isCoalescible(_ update: SessionUpdate) -> Bool {
        switch update {
        case .agentMessageChunk, .agentThoughtChunk:
            true
        case .userMessageChunk, .userMessage, .agentMessage, .agentThought, .stateUpdate, .toolCallContentChunk,
            .toolCallUpdate, .terminalUpdate, .terminalOutputChunk, .planUpdate, .availableCommandsUpdate,
            .configOptionUpdate, .sessionInfoUpdate, .usageUpdate, .unknown:
            false
        }
    }

    /// Receives one update.
    ///
    /// A coalescible chunk goes into the buffer, which flushes on the
    /// cadence. Any other update, and each chunk under a `.zero` cadence,
    /// flushes the buffer first and then applies at once.
    ///
    /// - Parameter update: The update to receive.
    func receive(_ update: SessionUpdate) {
        guard cadence > .zero, Self.isCoalescible(update) else {
            flush()
            applyUpdate(update)
            return
        }
        pendingChunks.append(update)
        scheduleFlushIfNeeded()
    }

    /// Folds the buffer into the owner at once, and cancels the scheduled
    /// flush. An empty buffer flushes to nothing.
    func flush() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard !pendingChunks.isEmpty else { return }
        let chunks = pendingChunks
        pendingChunks.removeAll(keepingCapacity: true)
        foldChunks(chunks)
    }

    /// Schedules one flush after the cadence, when no flush is scheduled.
    ///
    /// The task holds the coalescer weakly, so a released coalescer never
    /// keeps a timer alive. A synchronous flush cancels the task.
    private func scheduleFlushIfNeeded() {
        guard scheduledFlush == nil else { return }
        let cadence = cadence
        let clock = clock
        scheduledFlush = Task { [weak self] in
            // A cancelled sleep throws; the check below then stops the flush.
            try? await clock.sleep(for: cadence, tolerance: nil)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
