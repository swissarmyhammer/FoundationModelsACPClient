import Foundation
import FoundationModelsACP
import Observation

/// A plan, as an observable transcript entry.
///
/// The name is not `PlanEntry`, because the schema type `PlanEntry` is one
/// item of a plan. The engine replaces the plan with each update for the same
/// `planId`, and the entry keeps the position where the plan first appeared.
@MainActor @Observable
public final class PlanTranscriptEntry: ObservableTranscriptEntry {
    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The identifier of the plan, or `nil` for a plan of unknown content
    /// that names no `planId`.
    public internal(set) var planId: PlanId?

    /// The items of the plan. A plan of unknown content has no items.
    public internal(set) var entries: [PlanEntry] = []

    /// The `_meta` field of the last plan update.
    public internal(set) var meta: JSONValue?

    /// Makes the entry for a plan from the wire.
    ///
    /// - Parameter entry: The engine entry of the plan.
    init(wire entry: FoundationModelsACP.SessionEntry) {
        self.id = .wire(entry.id)
        update(from: entry)
    }

    /// Copies the merged state of the engine entry, and writes only the
    /// fields that changed.
    ///
    /// - Parameter entry: The engine entry of this plan.
    func update(from entry: FoundationModelsACP.SessionEntry) {
        guard case .plan(let plan) = entry.kind else {
            recordKindMismatch()
            return
        }
        assign(Self.planId(of: entry.id), to: \.planId)
        assign(Self.items(of: plan.plan), to: \.entries)
        assign(plan.meta, to: \.meta)
    }

    /// The plan identifier that the engine identity holds.
    ///
    /// - Parameter id: The engine identity of the plan entry.
    /// - Returns: The plan identifier, or `nil` for an unidentified entry.
    private static func planId(of id: FoundationModelsACP.SessionEntry.ID) -> PlanId? {
        guard case .plan(let planId) = id else { return nil }
        return planId
    }

    /// The items of plan content.
    ///
    /// - Parameter content: The content of the plan update.
    /// - Returns: The items, or no items for content of an unknown type.
    private static func items(of content: PlanUpdateContent) -> [PlanEntry] {
        switch content {
        case .items(let items): items.entries
        case .unknown: []
        }
    }
}
