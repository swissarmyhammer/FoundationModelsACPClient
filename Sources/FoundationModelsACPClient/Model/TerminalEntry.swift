import Foundation
import FoundationModelsACP
import Observation

/// An agent-owned terminal, as an observable transcript entry.
///
/// The engine appends the bytes of each output chunk, and an `output`
/// snapshot replaces them. This object shows the result.
@MainActor @Observable
public final class TerminalEntry: ObservableTranscriptEntry {
    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The output bytes of the terminal.
    public internal(set) var bytes = Data()

    /// The exit status, or `nil` while the command runs.
    public internal(set) var exitStatus: TerminalExitStatus?

    /// The command that the terminal runs.
    public internal(set) var command: String?

    /// The absolute working directory of the command.
    public internal(set) var cwd: AbsolutePath?

    /// The `_meta` field of the terminal.
    public internal(set) var meta: JSONValue?

    /// The output as text. Bytes that are not valid UTF-8 become the
    /// replacement character U+FFFD, so the text never fails.
    public var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Makes the entry for a terminal from the wire.
    ///
    /// - Parameter entry: The engine entry of the terminal.
    init(wire entry: FoundationModelsACP.SessionEntry) {
        self.id = .wire(entry.id)
        update(from: entry)
    }

    /// Copies the merged state of the engine entry, and writes only the
    /// fields that changed.
    ///
    /// - Parameter entry: The engine entry of this terminal.
    func update(from entry: FoundationModelsACP.SessionEntry) {
        guard case .terminal(_, let terminal) = entry.kind else {
            recordKindMismatch()
            return
        }
        assign(terminal.output, to: \.bytes)
        assign(terminal.exitStatus.currentValue, to: \.exitStatus)
        assign(terminal.command.currentValue, to: \.command)
        assign(terminal.cwd.currentValue, to: \.cwd)
        assign(terminal.meta.currentValue, to: \.meta)
    }
}
