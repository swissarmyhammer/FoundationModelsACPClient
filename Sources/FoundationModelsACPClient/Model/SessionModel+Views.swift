import FoundationModelsACP

// The derived views of the session tree, for a breadcrumb bar with a dropdown
// at each crumb and for a jump-to-session command. A view reads ready-to-show
// values and builds nothing. Each value follows one rule at every level: depth
// is not a case, and no depth is a limit.

/// One session in a path of the session tree, as a small value that is cheap
/// to compare.
public struct SessionPathEntry: Hashable, Sendable, Identifiable {
    /// The id of the session.
    public let sessionId: SessionId

    /// The title to show for the session: the title that the parent gave a
    /// child, or else the title of the session information, or else the
    /// session id.
    public let title: String

    /// The titles from the root session to this session, this session last.
    public let path: [String]

    /// The state of the foreground work of the session.
    public let workState: SessionWorkState

    /// The count of the pending permission requests and elicitations of the
    /// session itself. It does not count a descendant.
    public let pendingRequestCount: Int

    /// Whether this session or a descendant needs the user. See
    /// ``SessionModel/needsAttention``.
    public let needsAttention: Bool

    /// Whether the work state is current. A child is unconfirmed after a
    /// resume until its first current snapshot.
    public let isConfirmed: Bool

    /// The reason that the session failed to restore, or `nil`.
    public let restoreFailure: String?

    /// The id of the entry, which is the session id.
    public var id: SessionId { sessionId }
}

extension SessionModel {
    /// The title to show for this session: ``title`` for a child, else the
    /// title of ``sessionInfo``, else the session id.
    public var displayTitle: String {
        title ?? sessionInfo.title.currentValue ?? sessionId.rawValue
    }

    /// The count of the pending permission requests and elicitations of this
    /// session. It does not count a descendant.
    public var pendingRequestCount: Int {
        pendingRequests.count
    }

    /// Whether this session or any descendant is waiting for the user: its
    /// work state is `requires_action`, or it has a pending request. A closed
    /// session never needs attention. The value is computed, so a question
    /// deep in the tree shows on each ancestor, and each view gets the same
    /// answer.
    public var needsAttention: Bool {
        ownNeedsAttention || children.contains { $0.needsAttention }
    }

    /// Whether this session itself waits for the user: its work state is
    /// `requires_action`, or it has a pending request. A descendant does not
    /// count. A closed session never waits.
    public var ownNeedsAttention: Bool {
        guard !isClosed else { return false }
        return workState == .requiresAction || pendingRequestCount > 0
    }

    /// The first session in this tree that waits itself, this session first,
    /// then each descendant depth first, or `nil` when none waits.
    public var firstWaitingSession: SessionModel? {
        firstSession { $0.ownNeedsAttention }
    }

    /// The first session of this tree, this session first and then each
    /// descendant depth first, for which a test holds.
    ///
    /// - Parameter matches: The test.
    /// - Returns: The session, or `nil` when the test holds for none.
    private func firstSession(where matches: (SessionModel) -> Bool) -> SessionModel? {
        if matches(self) { return self }
        for child in children {
            if let found = child.firstSession(where: matches) { return found }
        }
        return nil
    }

    /// The count of the pending requests of this session and of each
    /// descendant. A collapsed crumb shows it.
    public var branchPendingRequestCount: Int {
        pendingRequestCount + children.reduce(0) { $0 + $1.branchPendingRequestCount }
    }

    /// The root session of this tree: the session with no parent.
    public var root: SessionModel {
        parent?.root ?? self
    }

    /// The sessions from the root to this session, root first, this session
    /// last.
    public var path: [SessionModel] {
        (parent?.path ?? []) + [self]
    }

    /// Finds a session in this tree, this session included.
    ///
    /// - Parameter sessionId: The id of the session.
    /// - Returns: The model, or `nil` when no session of this tree has that id.
    public func session(withId sessionId: SessionId) -> SessionModel? {
        firstSession { $0.sessionId == sessionId }
    }

    /// The closest ancestor that is not closed, or `nil` when none is. A
    /// view that shows a removed child falls back to it.
    public var nearestOpenAncestor: SessionModel? {
        var next = parent
        while let session = next {
            if !session.isClosed { return session }
            next = session.parent
        }
        return nil
    }

    /// Why the work state of this session is what it is, so a view does not
    /// have to guess among the causes of an unknown state.
    public var status: SessionStatus {
        if let restoreFailure { return .restoreFailed(reason: restoreFailure) }
        if parent != nil, !isWorkStateConfirmed { return .unconfirmed }
        return switch workState {
        case .running: .running
        case .requiresAction: .requiresAction
        case .idle(let stopReason, let error): .idle(stopReason: stopReason, error: error)
        case .unknown: .unknown
        }
    }

    /// Whether a view can send a prompt to this session. Only an open root
    /// session takes a prompt.
    public var canPrompt: Bool {
        !isClosed && parent == nil
    }

    /// Whether a view can cancel the work of this session. A root session can.
    /// A child can when it is confirmed and its capabilities advertise the
    /// cancel.
    public var canCancel: Bool {
        guard !isClosed else { return false }
        guard parent != nil else { return true }
        return isWorkStateConfirmed && restoreFailure == nil && capabilities?.cancel != nil
    }

    /// This session as one path entry.
    public var pathEntry: SessionPathEntry {
        SessionPathEntry(
            sessionId: sessionId,
            title: displayTitle,
            path: pathTitles,
            workState: workState,
            pendingRequestCount: pendingRequestCount,
            needsAttention: needsAttention,
            isConfirmed: isWorkStateConfirmed,
            restoreFailure: restoreFailure
        )
    }

    /// The chain from the root session to the parent of this session, root
    /// first. Each element is one crumb. A root session has none.
    public var ancestors: [SessionPathEntry] {
        var chain: [SessionPathEntry] = []
        var next = parent
        while let session = next {
            chain.append(session.pathEntry)
            next = session.parent
        }
        return chain.reversed()
    }

    /// The choices of the crumb of this session, in announce order, this
    /// session included. For a root session, the choices are the root
    /// sessions of the connection.
    public var siblings: [SessionPathEntry] {
        if let parent {
            return parent.children.map(\.pathEntry)
        }
        return (owner?.openSessions ?? [self]).map(\.pathEntry)
    }

    /// All sessions below this session, depth first, in announce order. The
    /// list is computed from ``children`` and keeps no copy.
    public var descendants: [SessionPathEntry] {
        children.flatMap { [$0.pathEntry] + $0.descendants }
    }

    /// The titles from the root session to this session, this session last.
    var pathTitles: [String] {
        path.map(\.displayTitle)
    }
}

/// Why a session shows the state that it shows.
public enum SessionStatus: Hashable, Sendable {
    /// The agent works.
    case running

    /// The agent waits for an action of the user.
    case requiresAction

    /// The agent does not work.
    case idle(stopReason: StopReason?, error: ACPError?)

    /// A child waits for its first current snapshot after a resume. Its state
    /// is not known, and it allows no operation.
    case unconfirmed

    /// The session failed to restore, for the given reason.
    case restoreFailed(reason: String)

    /// The agent reported no state, or a state that this schema revision does
    /// not know.
    case unknown
}
