import FoundationModelsACP

// The child-session state of a session model. A child is a session model like
// each other one, with a parent. The connection model makes it when the
// parent receives a `subagent_update`, and it gives each folded announcement
// to ``applyAnnouncement(_:)``.

/// An operation that the client refuses on a child session, with no request.
public enum SubagentSessionError: Error, Hashable, Sendable {
    /// The agent does not allow the operation on a child session. The model
    /// sent no request.
    ///
    /// - Parameter operation: The ACP wire method of the operation, for
    ///   example `session/prompt`.
    case notPermitted(operation: String)
}

/// The state of the foreground work of a session, in the words of the user
/// interface.
public enum SessionWorkState: Hashable, Sendable {
    /// The agent works.
    case running

    /// The agent waits for an action of the user.
    case requiresAction

    /// The agent does not work.
    ///
    /// - Parameters:
    ///   - stopReason: Why the last work ended, when the agent said it.
    ///   - error: The error that ended the work, when there was one.
    case idle(stopReason: StopReason?, error: ACPError?)

    /// The model has no state of the agent, or the state is of a kind that
    /// this schema revision does not know. The session is not known to be
    /// idle.
    case unknown
}

extension SessionModel {
    /// The state of the foreground work, from ``agentState``.
    public var workState: SessionWorkState {
        if parent != nil, !isWorkStateConfirmed { return .unknown }
        return switch agentState {
        case .running: .running
        case .requiresAction: .requiresAction
        case .idle(let idle): .idle(stopReason: idle.stopReason, error: idle.error)
        case .unknown, nil: .unknown
        }
    }

    /// Writes the folded announcement of this child.
    ///
    /// Each field of the fold is the whole current value, so a field that no
    /// update gave is `nil`. A snapshot of a replay is history: it writes the
    /// description of the child, and it never writes the capabilities or the
    /// state, and never confirms the child. A current snapshot writes them and
    /// confirms the child. The state is written only when the parent changed
    /// it, because the child sends its own `state_update` too.
    ///
    /// - Parameters:
    ///   - announcement: The folded `subagent_update` of this child.
    ///   - isHistory: Whether the announcement is part of a replay.
    func applyAnnouncement(_ announcement: SubagentUpdate, isHistory: Bool) {
        // A description field that the snapshot did not give keeps its value:
        // after a replay boundary the first current snapshot folds on a fresh
        // base, and an omitted title is not a cleared title.
        writeIfGiven(announcement.title, to: \.title)
        writeIfGiven(announcement.description, to: \.description)
        writeIfGiven(announcement.cwd, to: \.cwd)
        switch announcement.additionalDirectories {
        case .value(let directories): write(directories, to: \.additionalDirectories)
        case .cleared: write([], to: \.additionalDirectories)
        case .unchanged: break
        }
        if let toolCallId = SAH.AgentRun.extract(from: announcement.meta.currentValue)?.toolCallId {
            write(toolCallId, to: \.startedByToolCallId)
        }
        updateRestoreFailure(from: announcement, isHistory: isHistory)
        guard !isHistory else { return }
        write(announcement.capabilities.currentValue, to: \.capabilities)
        if announcement.state != mirroredState {
            mirroredState = announcement.state
            switch announcement.state {
            case .value(let state): changeAgentState(state)
            case .cleared: agentState = nil
            case .unchanged: break
            }
        }
        write(true, to: \.isWorkStateConfirmed)
    }

    /// Writes ``restoreFailure`` from an announcement.
    ///
    /// The reason is the explicit `_meta.sah.restoreFailure` of a CURRENT
    /// snapshot. A snapshot of a replay is history and sets nothing. A current
    /// snapshot whose state is known clears it. The model invents no failure of its own: a child
    /// with no current snapshot is only unconfirmed.
    ///
    /// - Parameters:
    ///   - announcement: The folded `subagent_update` of this child.
    ///   - isHistory: Whether the announcement is part of a replay.
    private func updateRestoreFailure(from announcement: SubagentUpdate, isHistory: Bool) {
        guard !isHistory else { return }
        if case .value(let state) = announcement.state, !state.isUnknown {
            write(nil, to: \.restoreFailure)
        } else if let failure = SAH.RestoreFailure.extract(from: announcement.meta.currentValue) {
            write(failure.reason, to: \.restoreFailure)
        }
    }

    /// Forgets the current state of each descendant: a resume makes the cached
    /// work state and capabilities of each child stale. Each child is
    /// unconfirmed until its first current snapshot.
    func invalidateChildren() {
        for child in children {
            child.write(nil, to: \.capabilities)
            child.write(nil, to: \.restoreFailure)
            child.mirroredState = .unchanged
            if child.agentState != nil { child.agentState = nil }
            child.write(false, to: \.isWorkStateConfirmed)
            child.invalidateChildren()
        }
    }

    /// Removes each child from the tree without closing it, and from the
    /// index of the connection model, so the replay can make new child models
    /// with the same ids. ``replayRollback`` keeps the old models.
    func setChildrenAside() {
        owner?.forgetChildren(children)
        children.removeAll()
    }

    /// Puts the child models that a failed replay set aside back into the tree
    /// and into the index of the connection model.
    ///
    /// - Parameter old: The child models that ``setChildrenAside()`` removed.
    func reviveChildren(_ old: [SessionModel]) {
        children = old
        owner?.reviveChildren(old)
    }

    /// Closes and removes each child, at each level.
    func closeChildren() {
        let closing = children
        children.removeAll()
        for child in closing {
            child.markClosed()
        }
    }

    /// Ends the replay of each child that still replays, at the end of the
    /// replay of this session. A child has no marker of its own.
    ///
    /// - Parameter succeeded: Whether the root replay ended with a result.
    func endChildReplays(succeeded: Bool) {
        for child in children where child.isReplaying {
            child.endReplay(succeeded: succeeded)
        }
    }

    /// Removes this child from its parent and closes it, at each level.
    func removeFromParent() {
        parent?.children.removeAll { $0 === self }
        markClosed()
    }

    /// Links each tool-call entry to the child that its `_meta.sah.agentRun`
    /// names, and removes each child whose started-by tool call reached a
    /// final status.
    func refreshChildLinks() {
        guard !children.isEmpty || transcript.contains(where: { if case .toolCall = $0 { true } else { false } }) else { return }
        for case .toolCall(let entry) in transcript {
            let linked = SAH.AgentRun.extract(from: entry.meta)?.sessionId
            entry.setChild(children.first { $0.sessionId == linked && linked != nil })
            guard let status = entry.status, status.isFinal else { continue }
            for child in children where child.startedByToolCallId == entry.toolCallId {
                child.removeFromParent()
                entry.setChild(nil)
            }
        }
    }

    /// Writes a patch field that the update gave: a value replaces, `null`
    /// clears, and an omitted field leaves the property as it is.
    ///
    /// - Parameters:
    ///   - field: The folded patch field.
    ///   - keyPath: The property to write.
    private func writeIfGiven<Value: Equatable>(
        _ field: PatchField<Value>,
        to keyPath: ReferenceWritableKeyPath<SessionModel, Value?>
    ) {
        switch field {
        case .value(let value): write(value, to: keyPath)
        case .cleared: write(nil, to: keyPath)
        case .unchanged: break
        }
    }

    /// Writes a value to a property only when the value is different, so an
    /// observer of a property that did not change sees no write.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - keyPath: The property to write.
    private func write<Value: Equatable>(_ value: Value, to keyPath: ReferenceWritableKeyPath<SessionModel, Value>) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    /// Adds a child at the end of ``children``.
    ///
    /// - Parameter child: The model of the new child.
    func addChild(_ child: SessionModel) {
        child.parent = self
        children.append(child)
    }

    /// Throws when this session is a child and does not allow an operation.
    ///
    /// The client allows on a child only what the capabilities of the child
    /// advertise. Today that is the cancel.
    ///
    /// - Parameters:
    ///   - operation: The ACP wire method of the operation.
    ///   - isAllowed: Whether the capabilities of the child allow it.
    /// - Throws: ``SubagentSessionError/notPermitted(operation:)``.
    func requireAllowedOnChild(_ operation: String, allowed isAllowed: (SubagentSessionCapabilities) -> Bool) throws {
        guard parent != nil else { return }
        guard let capabilities, isAllowed(capabilities) else {
            throw SubagentSessionError.notPermitted(operation: operation)
        }
    }
}

extension StateUpdate {
    /// Whether this is a state that this schema revision does not know, which
    /// the agent uses for a child that it lost.
    fileprivate var isUnknown: Bool {
        if case .unknown = self { true } else { false }
    }
}
