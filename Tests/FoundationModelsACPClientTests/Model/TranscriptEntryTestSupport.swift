import Foundation
import Observation
import Synchronization

@testable import FoundationModelsACPClient

// This file holds the shared helpers of the transcript model tests: one
// accessor for each kind of observable entry object, and the observation
// probe.

extension TranscriptEntry {
    /// The user-message object, or `nil` for another kind.
    var userMessage: UserMessageEntry? {
        if case .userMessage(let object) = self { object } else { nil }
    }

    /// The agent-message object, or `nil` for another kind.
    var agentMessage: AgentMessageEntry? {
        if case .agentMessage(let object) = self { object } else { nil }
    }

    /// The thought object, or `nil` for another kind.
    var thought: ThoughtEntry? {
        if case .thought(let object) = self { object } else { nil }
    }

    /// The tool-call object, or `nil` for another kind.
    var toolCall: ToolCallEntry? {
        if case .toolCall(let object) = self { object } else { nil }
    }

    /// The terminal object, or `nil` for another kind.
    var terminal: TerminalEntry? {
        if case .terminal(let object) = self { object } else { nil }
    }

    /// The plan object, or `nil` for another kind.
    var plan: PlanTranscriptEntry? {
        if case .plan(let object) = self { object } else { nil }
    }

    /// The unknown-update object, or `nil` for another kind.
    var unknown: UnknownEntry? {
        if case .unknown(let object) = self { object } else { nil }
    }

    /// The compaction object, or `nil` for another kind.
    var compaction: CompactionEntry? {
        if case .compaction(let object) = self { object } else { nil }
    }

    /// The error object, or `nil` for another kind.
    var error: ErrorEntry? {
        if case .error(let object) = self { object } else { nil }
    }
}

/// Tells if a write fires the observation of a read.
///
/// - Parameters:
///   - read: The reads that the observation tracks.
///   - write: The write to make after the tracking starts.
/// - Returns: `true` when the write fired `onChange`.
@MainActor
func observationFires(reading read: () -> Void, during write: () -> Void) -> Bool {
    let fired = Mutex(false)
    withObservationTracking(read) {
        fired.withLock { $0 = true }
    }
    write()
    return fired.withLock { $0 }
}
