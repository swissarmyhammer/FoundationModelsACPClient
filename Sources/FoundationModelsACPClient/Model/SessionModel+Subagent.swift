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
        switch agentState {
        case .running: .running
        case .requiresAction: .requiresAction
        case .idle(let idle): .idle(stopReason: idle.stopReason, error: idle.error)
        case .unknown, nil: .unknown
        }
    }

    /// Writes the folded announcement of this child.
    ///
    /// Each field of the fold is the whole current value, so a field that no
    /// update gave is `nil`. The state is the exception: the child sends its
    /// own `state_update` too, so the model writes a mirrored state only when
    /// the parent changed it.
    ///
    /// - Parameter announcement: The folded `subagent_update` of this child.
    func applyAnnouncement(_ announcement: SubagentUpdate) {
        write(announcement.title.currentValue, to: \.title)
        write(announcement.description.currentValue, to: \.description)
        write(announcement.capabilities.currentValue, to: \.capabilities)
        write(announcement.cwd.currentValue, to: \.cwd)
        write(announcement.additionalDirectories.currentValue ?? [], to: \.additionalDirectories)
        guard announcement.state != mirroredState else { return }
        mirroredState = announcement.state
        switch announcement.state {
        case .value(let state): changeAgentState(state)
        case .cleared: agentState = nil
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
