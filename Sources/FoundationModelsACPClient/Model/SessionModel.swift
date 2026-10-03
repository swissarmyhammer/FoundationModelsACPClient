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
@MainActor @Observable
public final class SessionModel {
    /// The identifier of the session.
    public let sessionId: SessionId

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

    /// The merge engine that holds the merge rules and the merged state.
    @ObservationIgnored private var engine = SessionMergeEngine()

    /// The object of each wire entry, keyed by its engine identity.
    ///
    /// The model finds the object of a changed entry by identity and not by
    /// the engine index, because the transcript can also hold entries that the
    /// client makes itself.
    @ObservationIgnored private var wireEntries: [FoundationModelsACP.SessionEntry.ID: TranscriptEntry] = [:]

    /// Makes the model of a session with an empty transcript and no state.
    ///
    /// - Parameter sessionId: The identifier of the session.
    init(sessionId: SessionId) {
        self.sessionId = sessionId
    }

    /// Folds one `session/update` into the model.
    ///
    /// - Parameter update: The update to fold.
    func apply(_ update: SessionUpdate) {
        reflect(engine.apply(update))
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
        case .sessionInfoChanged(let info): sessionInfo = info
        }
    }

    /// Appends the object of a new engine entry to the transcript.
    ///
    /// - Parameter entry: The engine entry that the engine added.
    private func addEntry(_ entry: FoundationModelsACP.SessionEntry) {
        let object = TranscriptEntry(wire: entry)
        wireEntries[entry.id] = object
        transcript.append(object)
    }

    /// Copies the merged state of a changed engine entry into its object.
    ///
    /// The engine changes only an entry that it added before, so the object
    /// is always there. A missing object is a defect: the assertion stops a
    /// debug build, the log records it in a release build, and the model
    /// stays unchanged.
    ///
    /// - Parameter entry: The engine entry that the engine changed.
    private func changeEntry(_ entry: FoundationModelsACP.SessionEntry) {
        guard let object = wireEntries[entry.id] else {
            assertionFailure("the engine changed an entry that the model does not have: \(entry.id)")
            Logger(label: ACPClientTelemetry.logLabel).error(
                "The merge engine changed a transcript entry that the session model does not have; the model stays unchanged.",
                metadata: [ACPClientTelemetry.LogMetadataKey.sessionID: "\(sessionId.rawValue)"]
            )
            return
        }
        object.update(from: entry)
    }
}
