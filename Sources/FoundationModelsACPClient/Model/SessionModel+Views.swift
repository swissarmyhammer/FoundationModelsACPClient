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
        guard !isClosed else { return false }
        if workState == .requiresAction || pendingRequestCount > 0 { return true }
        return children.contains { $0.needsAttention }
    }

    /// This session as one path entry.
    public var pathEntry: SessionPathEntry {
        SessionPathEntry(
            sessionId: sessionId,
            title: displayTitle,
            path: pathTitles,
            workState: workState,
            pendingRequestCount: pendingRequestCount,
            needsAttention: needsAttention
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
        (parent?.pathTitles ?? []) + [displayTitle]
    }
}
