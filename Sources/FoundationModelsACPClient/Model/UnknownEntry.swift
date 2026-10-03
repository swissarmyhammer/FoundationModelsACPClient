import Foundation
import FoundationModelsACP
import Observation

/// A session update that this revision of the schema does not know, as an
/// observable transcript entry.
///
/// The entry keeps the update type and the raw payload, so that no update is
/// dropped and a UI can show it as raw JSON.
@MainActor @Observable
public final class UnknownEntry: ObservableTranscriptEntry {
    /// The key of the `_meta` member in a raw payload.
    private static let metaKey = "_meta"

    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The `sessionUpdate` type of the update.
    public internal(set) var type = ""

    /// The raw payload of the update.
    public internal(set) var raw: JSONValue = .null

    /// The `_meta` member of the raw payload, or `nil` when it has none.
    public internal(set) var meta: JSONValue?

    /// Makes the entry for an unknown update from the wire.
    ///
    /// - Parameter entry: The engine entry of the update.
    init(wire entry: FoundationModelsACP.SessionEntry) {
        self.id = .wire(entry.id)
        update(from: entry)
    }

    /// Copies the merged state of the engine entry, and writes only the
    /// fields that changed.
    ///
    /// - Parameter entry: The engine entry of this update.
    func update(from entry: FoundationModelsACP.SessionEntry) {
        guard case .unknown(let type, let payload) = entry.kind else {
            recordKindMismatch()
            return
        }
        assign(type, to: \.type)
        assign(payload, to: \.raw)
        assign(Self.meta(of: payload), to: \.meta)
    }

    /// The `_meta` member of a raw payload.
    ///
    /// - Parameter payload: The raw payload of the update.
    /// - Returns: The member, or `nil` when the payload is not an object or
    ///   has no such member.
    private static func meta(of payload: JSONValue) -> JSONValue? {
        guard case .object(let members) = payload else { return nil }
        return members[metaKey]
    }
}
