import FoundationModelsACP

// The session list of `ConnectionModel`: the pages of `session/list`, the
// patch of a listed session from the `session_info_update` of its open
// model, and `session/delete`.

extension ConnectionModel.WireMethod {
    /// The request that lists the sessions of the agent, one page at a time.
    static let listSessions = "session/list"

    /// The request that deletes a session from the list of the agent.
    static let deleteSession = "session/delete"
}

extension ConnectionModel {
    /// How a page of `session/list` changes ``sessions``.
    private enum SessionPageMerge {
        /// The page replaces the list. A refresh gives the first page.
        case replace

        /// The page goes after the items of the list.
        case append
    }

    // MARK: - List

    /// Tells whether the agent has more sessions after the last page. It is
    /// `false` before the first refresh and after the last page.
    public var hasMoreSessions: Bool {
        sessionListCursor != nil
    }

    /// Sends `session/list` for the first page, and replaces ``sessions``
    /// with that page.
    ///
    /// The call keeps `cwd`, and each ``loadMoreSessions()`` sends it again.
    /// The call starts a new generation of the list, so a page of a load
    /// that was in flight when the refresh started does not change
    /// ``sessions``. The cursor of the last list goes away at the start, so
    /// ``hasMoreSessions`` is `false` until the first page arrives.
    ///
    /// - Parameter cwd: The working directory to filter the sessions by, or
    ///   `nil` for each session.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when
    ///   ``canListSessions`` is `false`, so the call sends nothing;
    ///   `ConnectionError.closed` when no connection is open; or the error of
    ///   the agent or of the connection. On an error, ``sessions`` does not
    ///   change.
    public func refreshSessions(cwd: AbsolutePath? = nil) async throws {
        try requireCapability(canListSessions, method: WireMethod.listSessions)
        let connection = try openConnection()
        sessionListGeneration += 1
        sessionListWorkingDirectory = cwd
        sessionListCursor = nil
        try await loadSessionPage(ListSessionsRequest(cwd: cwd), over: connection, merge: .replace)
    }

    /// Sends `session/list` for the next page, with the cursor and the
    /// working directory of the last page, and appends that page to
    /// ``sessions``.
    ///
    /// When ``hasMoreSessions`` is `false`, the call sends nothing. A page
    /// that arrives after a refresh started, or after another page landed,
    /// does not change ``sessions``.
    ///
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when
    ///   ``canListSessions`` is `false`, so the call sends nothing;
    ///   `ConnectionError.closed` when no connection is open; or the error of
    ///   the agent or of the connection. On an error, ``sessions`` does not
    ///   change.
    public func loadMoreSessions() async throws {
        try requireCapability(canListSessions, method: WireMethod.listSessions)
        guard let cursor = sessionListCursor else { return }
        let request = ListSessionsRequest(cursor: cursor, cwd: sessionListWorkingDirectory)
        try await loadSessionPage(request, over: try openConnection(), merge: .append)
    }

    /// Sends one `session/list` request, and puts its page in ``sessions``
    /// when no refresh and no other page changed the list in the meantime.
    ///
    /// - Parameters:
    ///   - request: The list request.
    ///   - connection: The connection that sends the request.
    ///   - merge: How the page changes ``sessions``.
    /// - Throws: The error of the agent or of the connection.
    private func loadSessionPage(
        _ request: ListSessionsRequest,
        over connection: ClientSideConnection,
        merge: SessionPageMerge
    ) async throws {
        let generation = sessionListGeneration
        let page = try await connection.listSessions(request)
        guard generation == sessionListGeneration else { return }
        sessionListGeneration += 1
        switch merge {
        case .replace: sessions = page.sessions
        case .append: sessions.append(contentsOf: page.sessions)
        }
        sessionListCursor = page.nextCursor
    }

    /// Patches the listed item of a session with the session information of
    /// its open model. A session that is not in ``sessions`` changes
    /// nothing.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - info: The session information that the model folded.
    func patchListedSession(_ sessionId: SessionId, with info: SessionInfoUpdate) {
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        sessions[index].apply(info)
    }

    // MARK: - Delete

    /// Sends `session/delete` for a session, and removes it from
    /// ``sessions``.
    ///
    /// When the session is open, the call first closes it with
    /// ``close(_:)``, so the agent gets `session/close` before
    /// `session/delete`, and the model of the session is closed. When the
    /// close fails, the call sends no delete.
    ///
    /// - Parameter sessionId: The id of the session to delete.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when
    ///   ``canDeleteSessions`` is `false`, so the call sends nothing;
    ///   `ConnectionError.closed` when no connection is open; or the error of
    ///   the agent or of the connection. On an error, the item stays in
    ///   ``sessions``.
    public func deleteSession(_ sessionId: SessionId) async throws {
        try requireCapability(canDeleteSessions, method: WireMethod.deleteSession)
        let connection = try openConnection()
        if let open = openSessions[sessionId] {
            try await close(open)
        }
        _ = try await connection.deleteSession(DeleteSessionRequest(sessionId: sessionId))
        sessions.removeAll { $0.sessionId == sessionId }
    }
}

extension SessionInfo {
    /// Applies the session information that a `session_info_update` gives:
    /// an omitted field keeps its value, `null` clears it, and a value
    /// replaces it.
    ///
    /// - Parameter update: The session information.
    fileprivate mutating func apply(_ update: SessionInfoUpdate) {
        title = update.title.applied(to: title)
        updatedAt = update.updatedAt.applied(to: updatedAt)
        meta = update.meta.applied(to: meta)
    }
}
