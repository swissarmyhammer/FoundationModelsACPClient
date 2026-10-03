import Foundation
import FoundationModelsACP

// The display-rate chunk coalescing of a session and its raw update tap.
// `agent_message_chunk` and `agent_thought_chunk` arrive at token rate. The
// model holds them in a buffer that is not observable, and folds the whole
// buffer on a display-rate cadence. The tap gives each raw update to non-UI
// consumers at its arrival, with no delay from the buffer.

extension SessionModel {
    /// The default coalescing cadence, in milliseconds.
    private static let defaultCoalescingCadenceMilliseconds = 33

    /// The default display-rate cadence for chunk coalescing.
    ///
    /// The value gives approximately 30 flushes for each second. That rate is
    /// smooth for a reader and far under the token rate.
    public static let defaultCoalescingCadence: Duration = .milliseconds(defaultCoalescingCadenceMilliseconds)

    // MARK: - Coalescing

    /// Folds the chunk buffer into the model at once, and cancels the
    /// scheduled flush.
    ///
    /// The flush folds all buffered chunks through the engine and writes each
    /// changed entry one time, with its last state. The host calls this when
    /// it must show every chunk that arrived, for example on connection close.
    /// An empty buffer flushes to nothing.
    public func flushPendingChunks() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard !pendingChunks.isEmpty else { return }
        let chunks = pendingChunks
        pendingChunks.removeAll(keepingCapacity: true)
        fold(chunks)
    }

    /// Tells whether an update goes into the chunk buffer.
    ///
    /// Only the two token-rate chunk cases coalesce. Each other case folds at
    /// once, so it is never delayed and never reordered.
    ///
    /// - Parameter update: The received update.
    /// - Returns: `true` for `agent_message_chunk` and `agent_thought_chunk`.
    static func isCoalescibleChunk(_ update: SessionUpdate) -> Bool {
        switch update {
        case .agentMessageChunk, .agentThoughtChunk:
            true
        case .userMessageChunk, .userMessage, .agentMessage, .agentThought, .stateUpdate, .toolCallContentChunk,
            .toolCallUpdate, .terminalUpdate, .terminalOutputChunk, .planUpdate, .availableCommandsUpdate,
            .configOptionUpdate, .sessionInfoUpdate, .usageUpdate, .unknown:
            false
        }
    }

    /// Appends one chunk to the buffer and schedules the flush.
    ///
    /// - Parameter chunk: The chunk update to buffer.
    func enqueue(_ chunk: SessionUpdate) {
        pendingChunks.append(chunk)
        scheduleFlushIfNeeded()
    }

    /// Schedules one flush after the cadence, when no flush is scheduled.
    ///
    /// The task holds the model weakly, so a released model never keeps a
    /// timer alive. A synchronous flush cancels the task.
    private func scheduleFlushIfNeeded() {
        guard scheduledFlush == nil else { return }
        let cadence = coalescingCadence
        let clock = clock
        scheduledFlush = Task { [weak self] in
            // A cancelled sleep throws; the check below then stops the flush.
            try? await clock.sleep(for: cadence, tolerance: nil)
            guard !Task.isCancelled else { return }
            self?.flushPendingChunks()
        }
    }

    // MARK: - Update tap

    /// Gives each raw `session/update` of this session, in arrival order, at
    /// its arrival.
    ///
    /// The chunk buffer does not delay the stream: a chunk comes out of the
    /// tap before the model folds it. Each call makes a new stream, and each
    /// stream gets each update that arrives after the call. The stream
    /// finishes when the model closes or is released. acp-client uses it to
    /// write the chunks to standard output as they arrive.
    ///
    /// - Returns: The stream of raw updates.
    public func updateTap() -> AsyncStream<SessionUpdate> {
        let (stream, continuation) = AsyncStream<SessionUpdate>.makeStream()
        updateTaps[UUID()] = continuation
        return stream
    }

    /// Finishes each open ``updateTap()`` stream.
    ///
    /// The close of the model and the end of its subscription call this, so
    /// no tap consumer stays suspended. A tap made after the call gets the
    /// updates that arrive after it.
    func finishUpdateTaps() {
        let taps = updateTaps.values
        updateTaps.removeAll()
        for tap in taps {
            tap.finish()
        }
    }

    /// Gives one update to each open tap, and drops each tap whose consumer
    /// stopped.
    ///
    /// - Parameter update: The received update.
    func yieldToUpdateTaps(_ update: SessionUpdate) {
        for (id, tap) in updateTaps {
            if case .terminated = tap.yield(update) {
                updateTaps[id] = nil
            }
        }
    }
}

extension SessionMergeEngine.Change {
    /// Collapses the changes of one fold to one change for each entry.
    ///
    /// The change of an entry keeps the slot of its first change and takes
    /// the entry state of its last change, so an added entry stays an
    /// addition. A change that names no entry stays as it is, in its order.
    ///
    /// - Parameter changes: The changes that the engine returned, in order.
    /// - Returns: The collapsed changes, in the order of first appearance.
    static func collapsed(_ changes: [Self]) -> [Self] {
        var collapsed: [Self] = []
        var slots: [FoundationModelsACP.SessionEntry.ID: Int] = [:]
        for change in changes {
            guard let entry = change.changedEntry else {
                collapsed.append(change)
                continue
            }
            if let slot = slots[entry.id] {
                collapsed[slot] = collapsed[slot].replacingEntry(with: entry)
            } else {
                slots[entry.id] = collapsed.count
                collapsed.append(change)
            }
        }
        return collapsed
    }

    /// The entry that this change adds or changes, or `nil` for a change of
    /// last-value state.
    private var changedEntry: FoundationModelsACP.SessionEntry? {
        switch self {
        case .entryAdded(_, let entry), .entryChanged(_, let entry):
            entry
        case .availableCommandsChanged, .configOptionsChanged, .usageChanged, .agentStateChanged,
            .sessionInfoChanged:
            nil
        }
    }

    /// Returns this change with another state of its entry.
    ///
    /// - Parameter entry: The later state of the same entry.
    /// - Returns: The change with that state, or this change when it names no
    ///   entry.
    private func replacingEntry(with entry: FoundationModelsACP.SessionEntry) -> Self {
        switch self {
        case .entryAdded(let index, _):
            .entryAdded(index: index, entry: entry)
        case .entryChanged(let index, _):
            .entryChanged(index: index, entry: entry)
        case .availableCommandsChanged, .configOptionsChanged, .usageChanged, .agentStateChanged,
            .sessionInfoChanged:
            self
        }
    }
}
