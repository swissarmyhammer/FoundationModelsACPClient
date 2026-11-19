import ACPMarkdown
import FoundationModelsACP

// The read-only model of a share snapshot (D208). A recipient of a shared
// session sees the chat of the snapshot, with no composer. The model applies
// the updates of the snapshot through `apply(_:)`, the update path of a live
// model, so it shows the transcript that a live model shows for the same
// updates. It has no connection, and no `ConnectionModel` holds it.

extension SessionModel {
    /// Makes a read-only model that shows a share snapshot.
    ///
    /// The model applies each update of `snapshot.updates` in order, through
    /// ``apply(_:)``, before the initializer returns. It has no connection:
    /// it is not in ``ConnectionModel/openSessions`` of a connection, and no
    /// connection gives it updates. ``isReadOnly`` is `true`.
    ///
    /// A prompt, a cancel and a configuration change (also a change of the
    /// mode) throw ``SessionModelError/readOnly`` before they send anything.
    /// ``ConnectionModel/close(_:)`` refuses this model the same way.
    ///
    /// The fork (also a fork with a cut, a rewind), the resume (with its
    /// replay) and the delete of a ``ConnectionModel`` name a session by its
    /// id, and find only a model of ``ConnectionModel/openSessions``. This
    /// model is in no ``ConnectionModel/openSessions``, so they never change
    /// it. ``ConnectionModel/forkSession(_:cut:)`` with the id of this model
    /// throws ``ConnectionModelError/sessionNotOpen(sessionId:)`` and sends
    /// nothing, when the connection has no open model of the same id.
    ///
    /// The agent never sends a permission request or an elicitation to
    /// this model, because the model has no connection. Thus
    /// ``pendingPermissions``, ``pendingElicitations`` and
    /// ``pendingRequests`` are always empty, and there is nothing to answer.
    ///
    /// - Parameters:
    ///   - snapshot: The share snapshot to show.
    ///   - sessionId: The id of the shared session. The snapshot does not
    ///     hold it, so the caller gives it, for example from the record of
    ///     the share.
    public convenience init(snapshot: SessionSnapshot, sessionId: SessionId) {
        self.init(snapshot: snapshot, sessionId: sessionId, requestSender: ReadOnlySessionRequestSender())
    }

    /// Makes a read-only model that shows a share snapshot, with a request
    /// sender that a test gives. A test gives a fake sender to prove that
    /// the model sends nothing.
    ///
    /// - Parameters:
    ///   - snapshot: The share snapshot to show.
    ///   - sessionId: The id of the shared session.
    ///   - requestSender: The sender of the requests of the model.
    convenience init(snapshot: SessionSnapshot, sessionId: SessionId, requestSender: any SessionRequestSender) {
        self.init(sessionId: sessionId, requestSender: requestSender, coalescingCadence: .zero, isReadOnly: true)
        applyTitle(of: snapshot)
        applyUpdates(of: snapshot)
    }

    /// Shows a newer snapshot of the same share, for example after Update
    /// Share of the owner.
    ///
    /// When the entries of this model are the first entries of the newer
    /// snapshot, the model changes in place, through ``apply(_:)``:
    ///
    /// - An entry that stays the same keeps its object, its ``TranscriptEntry/id``
    ///   and its position, so a view keeps its scroll position.
    /// - An entry that changed keeps its object, its id and its position, and
    ///   gets the newer content.
    /// - Each new entry goes to the end of ``transcript``, in order.
    ///
    /// When the newer snapshot does not start with the same entries, for
    /// example when it has fewer entries or a different first entry, the
    /// model rebuilds: it clears the transcript and applies each update of
    /// the newer snapshot. Each entry then gets a new object, so a view can
    /// lose its scroll position. The model also rebuilds when an in-place
    /// change does not give the entries of the newer snapshot.
    ///
    /// The title of ``sessionInfo`` becomes the title of the newer snapshot.
    ///
    /// - Parameter snapshot: The newer snapshot.
    /// - Throws: ``SessionModelError/notReadOnly`` when ``isReadOnly`` is
    ///   `false`. A model of a connection gets its updates from the agent,
    ///   so the model does not change.
    public func replace(with snapshot: SessionSnapshot) throws {
        guard isReadOnly else { throw SessionModelError.notReadOnly }
        if !changeInPlace(to: SessionMergeEngine(replaying: snapshot.updates)) {
            resetTranscript()
            applyUpdates(of: snapshot)
        }
        applyTitle(of: snapshot)
    }

    /// Refuses a request to the agent on a read-only model.
    ///
    /// Each method that sends to the agent calls this guard first, before it
    /// changes the model or sends anything: the prompt, the cancel, the
    /// configuration change (also the change of the mode), and
    /// ``ConnectionModel/close(_:)``. A read-only model has no pending
    /// request to answer, so the answers need no guard.
    ///
    /// - Throws: ``SessionModelError/readOnly`` when ``isReadOnly`` is `true`.
    func requireWritable() throws {
        guard !isReadOnly else { throw SessionModelError.readOnly }
    }

    /// Applies each update of a snapshot through ``apply(_:)``, in order.
    ///
    /// - Parameter snapshot: The share snapshot.
    private func applyUpdates(of snapshot: SessionSnapshot) {
        for update in snapshot.updates {
            apply(update)
        }
    }

    /// Changes the transcript in place to the entries of a newer snapshot,
    /// when the current entries are its first entries.
    ///
    /// The model applies, through ``apply(_:)``, the replay update of each
    /// newer entry that is different or new, in engine order. The engine
    /// changes a known entry in place and adds a new entry at the end.
    ///
    /// - Parameter newer: An engine that replayed the updates of the newer
    ///   snapshot.
    /// - Returns: `true` when the model now holds the entries of `newer`.
    ///   `false` when the newer entries do not start with the current
    ///   entries, or when the in-place change did not give the newer
    ///   entries. The caller then rebuilds the model.
    private func changeInPlace(to newer: SessionMergeEngine) -> Bool {
        let current = wireEntries
        guard newer.entries.count >= current.count,
            zip(current, newer.entries).allSatisfy({ $0.id == $1.id })
        else { return false }
        let replayUpdates = newer.transcriptUpdates
        for (index, entry) in newer.entries.enumerated() where index >= current.count || current[index] != entry {
            apply(replayUpdates[index])
        }
        return wireEntries == newer.entries
    }

    /// Sets the title of ``sessionInfo`` to the title of the share.
    ///
    /// The updates of a snapshot hold no `session_info_update`, so the title
    /// comes from `snapshot.options.title`. The model applies it as a
    /// `session_info_update` through ``apply(_:)``, the update path of a live
    /// model. A snapshot with no title clears the title. When the title does
    /// not change, the model applies nothing.
    ///
    /// - Parameter snapshot: The share snapshot.
    private func applyTitle(of snapshot: SessionSnapshot) {
        let title = snapshot.options.title
        guard sessionInfo.title.currentValue != title else { return }
        let field: PatchField<String> = title.map { .value($0) } ?? .cleared
        apply(.sessionInfoUpdate(SessionInfoUpdate(title: field)))
    }
}
