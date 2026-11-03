import FoundationModelsACP

// The child sessions of the connection model. A child is a session model
// like each other one, with a parent, and the model is parent and child all
// the way down: the same rules hold at each level, and no code path depends
// on the depth. A child is not in ``ConnectionModel/openSessions``. The tree
// under each open session reaches it.

extension ConnectionModel {
    /// Gives the model of a child session, at any level under an open
    /// session.
    ///
    /// - Parameter sessionId: The id of the child.
    /// - Returns: The model, or `nil` when no announced child has that id.
    func childSession(for sessionId: SessionId) -> SessionModel? {
        func find(in session: SessionModel) -> SessionModel? {
            for child in session.children {
                if child.sessionId == sessionId { return child }
                if let found = find(in: child) { return found }
            }
            return nil
        }
        for root in openSessions {
            if let found = find(in: root) { return found }
        }
        return nil
    }

    /// Makes or changes the child that a `subagent_update` announced.
    ///
    /// The first announcement of a child makes its model, subscribes it to
    /// its updates, and adds it to the children of its parent, before any
    /// event of its id reaches it. A later announcement changes the same
    /// model. The engine of the parent already folded the patch rules.
    ///
    /// - Parameters:
    ///   - announcement: The folded state of the child.
    ///   - parent: The session that announced the child.
    func applySubagent(_ announcement: SubagentUpdate, under parent: SessionModel) {
        if let child = parent.children.first(where: { $0.sessionId == announcement.sessionId }) {
            child.applyAnnouncement(announcement, isHistory: parent.isReplayingHistory)
            parent.refreshChildLinks()
            return
        }
        guard let connection, session(for: announcement.sessionId) == nil,
            childSession(for: announcement.sessionId) == nil
        else {
            connectionLogger.log(
                "ignored the announcement of the child \"\(announcement.sessionId.rawValue)\", which already has a model"
            )
            return
        }
        let child = makeSubscribedSessionModel(sessionId: announcement.sessionId, over: connection)
        if parent.isReplayingHistory {
            // A child of a replay is history until the response of the root
            // request ends its replay, and it is unconfirmed after that.
            child.isWorkStateConfirmed = false
            child.replayPhase = parent.replayPhase
        }
        parent.addChild(child)
        child.applyAnnouncement(announcement, isHistory: parent.isReplayingHistory)
        attachToEvents(child)
        parent.refreshChildLinks()
    }

    /// Throws when a session id names a child, because the client sends no
    /// request that closes, resumes or deletes a child.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - operation: The ACP wire method of the operation.
    /// - Throws: ``SubagentSessionError/notPermitted(operation:)``.
    func refuseChild(_ sessionId: SessionId, operation: String) throws {
        guard childSession(for: sessionId) != nil else { return }
        throw SubagentSessionError.notPermitted(operation: operation)
    }
}
