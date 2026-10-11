import Foundation
import FoundationModelsACP
import Observation

/// The start time and the end time of one transcript entry, as the client saw
/// them.
///
/// No session update carries a time, and the `_meta` of an update is not a
/// source of times. Thus each time comes from the wall clock of the session
/// model when the model sees the event. An entry that the client did not see
/// live, for example an entry of a replay, keeps both times `nil`.
///
/// Each time is written one time and never moves. A streamed chunk writes no
/// time, so a row that shows a time is not redrawn for each chunk.
@MainActor @Observable
public final class EntryTiming {
    /// The client time when the entry started, or `nil` when the client did
    /// not see the start live.
    public private(set) var startedAt: Date?

    /// The client time when the entry ended, or `nil` while the entry has not
    /// ended, when the entry has no end, or when the client did not see the
    /// start live.
    public private(set) var endedAt: Date?

    /// The time from ``startedAt`` to ``endedAt``, in seconds, or `nil`
    /// unless both times exist.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// Whether the entry started live and did not end yet.
    var isOpen: Bool {
        startedAt != nil && endedAt == nil
    }

    /// Makes the timing of an entry with no times.
    init() {}

    /// Records the start time. A start that is set does not move.
    ///
    /// - Parameter date: The client time of the start.
    func start(at date: Date) {
        guard startedAt == nil else { return }
        startedAt = date
    }

    /// Records the end time. Only an open entry ends, so an entry that the
    /// client did not see start gets no end, and an end that is set does not
    /// move.
    ///
    /// - Parameter date: The client time of the end.
    func end(at date: Date) {
        guard isOpen else { return }
        endedAt = date
    }
}

extension ObservableTranscriptEntry {
    /// The client time when the entry started. See ``EntryTiming/startedAt``.
    public var startedAt: Date? {
        timing.startedAt
    }

    /// The client time when the entry ended. See ``EntryTiming/endedAt``.
    public var endedAt: Date? {
        timing.endedAt
    }

    /// The time from ``startedAt`` to ``endedAt``, in seconds. See
    /// ``EntryTiming/duration``.
    public var duration: TimeInterval? {
        timing.duration
    }
}

extension TranscriptEntry {
    /// The event that ends the timing of an entry.
    enum TimingEnd: Equatable {
        /// The entry ends when it starts: a user message and an error.
        case atStart

        /// The entry ends when the next entry starts, or when an idle
        /// `state_update` arrives: an agent message, a thought, and an
        /// unknown update.
        case atNextEntry

        /// The entry ends when its own state tells that its work finished: a
        /// tool call, a terminal, and a compaction.
        ///
        /// - Parameter isFinished: Whether the entry has finished now.
        case atFinish(isFinished: Bool)

        /// The entry has no natural end: a plan, which each plan update
        /// replaces in its first position.
        case never
    }

    /// The timing of the entry. See ``EntryTiming``.
    @MainActor
    public var timing: EntryTiming {
        switch self {
        case .userMessage(let entry): entry.timing
        case .agentMessage(let entry): entry.timing
        case .thought(let entry): entry.timing
        case .toolCall(let entry): entry.timing
        case .terminal(let entry): entry.timing
        case .plan(let entry): entry.timing
        case .unknown(let entry): entry.timing
        case .compaction(let entry): entry.timing
        case .error(let entry): entry.timing
        }
    }

    /// The end rule of the entry, with the finish state of an entry that
    /// ends when its work finishes.
    ///
    /// - A tool call finishes when its status is `completed`, `failed`, or
    ///   `cancelled`.
    /// - A terminal finishes when its exit status arrives.
    /// - A compaction finishes when its status is `completed`, `failed`, or
    ///   `cancelled`.
    @MainActor
    var timingEnd: TimingEnd {
        switch self {
        case .userMessage, .error: .atStart
        case .agentMessage, .thought, .unknown: .atNextEntry
        case .toolCall(let entry): .atFinish(isFinished: entry.status.map(Self.isFinished) ?? false)
        case .terminal(let entry): .atFinish(isFinished: entry.exitStatus != nil)
        case .compaction(let entry): .atFinish(isFinished: Self.isFinished(entry.status))
        case .plan: .never
        }
    }

    /// Tells whether a tool-call status is a final status.
    ///
    /// - Parameter status: The status of the tool call.
    /// - Returns: `true` for `completed`, `failed`, and `cancelled`.
    private static func isFinished(_ status: ToolCallStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled: true
        case .pending, .inProgress, .unknown: false
        }
    }

    /// Tells whether a compaction status is a final status.
    ///
    /// - Parameter status: The status of the compaction.
    /// - Returns: `true` for `completed`, `failed`, and `cancelled`.
    private static func isFinished(_ status: CompactionStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled: true
        case .inProgress, .unknown: false
        }
    }
}

/// The wall clock of a transcript, and the one entry that ends when the next
/// entry starts.
///
/// A session model holds one timekeeper. It tells the timekeeper each entry
/// that starts live, each change of an entry, and each idle `state_update`.
/// The timekeeper reads the wall clock only when it writes a time.
@MainActor
struct TranscriptTimekeeper {
    /// Gives the current client time.
    let now: @Sendable () -> Date

    /// The timing of the last live entry that ends when the next entry
    /// starts, or `nil` when no such entry is open.
    private var openEntry: EntryTiming?

    /// Makes a timekeeper with no open entry.
    ///
    /// - Parameter now: Gives the current client time.
    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// Records the start of an entry that the client sees live, and ends the
    /// open entry at the same time.
    ///
    /// - Parameter entry: The entry that starts.
    mutating func entryDidStart(_ entry: TranscriptEntry) {
        let date = now()
        endOpenEntry(at: date)
        entry.timing.start(at: date)
        switch entry.timingEnd {
        case .atStart, .atFinish(isFinished: true): entry.timing.end(at: date)
        case .atNextEntry: openEntry = entry.timing
        case .atFinish(isFinished: false), .never: break
        }
    }

    /// Ends an open entry whose work finished with this change. A change of
    /// any other entry writes no time.
    ///
    /// - Parameter entry: The entry that changed.
    func entryDidChange(_ entry: TranscriptEntry) {
        guard entry.timingEnd == .atFinish(isFinished: true), entry.timing.isOpen else { return }
        entry.timing.end(at: now())
    }

    /// Ends the open entry, because the agent became idle.
    mutating func agentDidBecomeIdle() {
        guard openEntry != nil else { return }
        endOpenEntry(at: now())
    }

    /// Forgets the open entry, for example when the transcript is cleared.
    mutating func reset() {
        openEntry = nil
    }

    /// Ends the open entry at a time, and forgets it.
    ///
    /// - Parameter date: The client time of the end.
    private mutating func endOpenEntry(at date: Date) {
        openEntry?.end(at: date)
        openEntry = nil
    }
}
