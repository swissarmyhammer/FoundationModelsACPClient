import Foundation
import FoundationModelsACP
import Observation

/// **UNSTABLE**
///
/// A context compaction, as an observable transcript entry.
///
/// A compaction changes only the model context of the agent. The transcript
/// keeps the full history, so this entry is a mark at the position where the
/// compaction first appeared, and no earlier entry changes. Each later
/// `compaction_update` changes this entry, and each
/// `compaction_summary_chunk` appends to its ``summary``.
@MainActor @Observable
public final class CompactionEntry: ObservableTranscriptEntry {
    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The identifier of the compaction.
    public let compactionId: Unstable.CompactionId

    /// The status from the last `compaction_update`. Before the first
    /// update, the status is `SessionEntry.Compaction.unreportedStatus`; see
    /// ``hasReportedStatus``.
    public internal(set) var status: Unstable.CompactionStatus

    /// The summary that the compaction keeps. A chunk appends a block; an
    /// update with a summary replaces it; an update with `null` or an empty
    /// list clears it.
    public internal(set) var summary: [ContentBlock] = []

    /// The reason that the compaction failed, or `nil` when the agent gave
    /// none or cleared it.
    public internal(set) var error: String?

    /// The `_meta` field of the compaction.
    public internal(set) var meta: JSONValue?

    /// Whether a `compaction_update` gave a status. A summary chunk that
    /// arrives before any update makes the entry with no reported status, and
    /// a view then shows "no status yet".
    public var hasReportedStatus: Bool {
        status != FoundationModelsACP.SessionEntry.Compaction.unreportedStatus
    }

    /// Makes the entry for a compaction from the wire.
    ///
    /// - Parameters:
    ///   - entry: The engine entry of the compaction.
    ///   - compaction: The merged compaction that the entry holds.
    init(wire entry: FoundationModelsACP.SessionEntry, compaction: FoundationModelsACP.SessionEntry.Compaction) {
        self.id = .wire(entry.id)
        self.compactionId = compaction.compactionId
        self.status = compaction.status
        copy(compaction)
    }

    /// Copies the merged state of the engine entry, and writes only the
    /// fields that changed. The identity and the compaction id do not
    /// change.
    ///
    /// - Parameter entry: The engine entry of this compaction.
    func update(from entry: FoundationModelsACP.SessionEntry) {
        guard case .compaction(let compaction) = entry.kind else {
            recordKindMismatch()
            return
        }
        copy(compaction)
    }

    /// Writes each changed field of a merged compaction.
    ///
    /// - Parameter compaction: The merged compaction.
    private func copy(_ compaction: FoundationModelsACP.SessionEntry.Compaction) {
        assign(compaction.status, to: \.status)
        assign(compaction.summary, to: \.summary)
        assign(compaction.error.currentValue, to: \.error)
        assign(compaction.meta.currentValue, to: \.meta)
    }
}
