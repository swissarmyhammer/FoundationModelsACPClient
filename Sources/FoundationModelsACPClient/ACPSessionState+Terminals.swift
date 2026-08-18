import Foundation
import FoundationModelsACP

// The terminal display surface. A client renders the terminals the agent
// owns, and it never drives them: ACP v2 gives the client no terminal
// control methods. The wire package's `SessionUpdateAggregator` holds the
// accumulation rules — `terminal_update` upserts by `terminalId`, a snapshot
// replaces the accumulated output, and `terminal_output_chunk` appends
// decoded bytes — so this file adds only the display helpers.

extension ACPSessionState {
    /// Resolves a `{"type": "terminal"}` content reference to its
    /// accumulated terminal.
    ///
    /// An unknown `terminalId` gives `nil`, so a reference that arrives
    /// before its terminal degrades to "no terminal to show" instead of a
    /// failure.
    ///
    /// - Parameter reference: The display-only terminal reference from
    ///   tool-call content.
    /// - Returns: The accumulated terminal, or `nil` for an unknown id.
    public func terminal(for reference: Terminal) -> AccumulatedTerminal? {
        terminals[reference.terminalId]
    }
}

extension AccumulatedTerminal {
    /// The accumulated output, rendered as text.
    ///
    /// Terminal output is bytes, not text, and a real shell can emit bytes
    /// that are not valid UTF-8. This is the documented rendering fallback:
    /// a lossy UTF-8 decode in which each invalid byte sequence becomes the
    /// Unicode replacement character (U+FFFD). The decode never fails, and
    /// it drops no data — the raw bytes stay available in ``output``.
    public var transcript: String {
        String(decoding: output, as: UTF8.self)
    }
}
