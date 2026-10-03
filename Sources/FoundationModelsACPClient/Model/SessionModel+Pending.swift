import Foundation
import FoundationModelsACP

// The pending requests of a session: the permission requests and the
// session-scoped elicitations that wait for the user's answer. Each one is
// observable pending state that the UI binds to and resolves. Each resolution
// removes the item and resumes the agent's call exactly one time; the shared
// `PendingRequestQueue` holds that lifecycle.

extension SessionModel {
    /// The permission requests that wait for the user's answer, in arrival
    /// order.
    ///
    /// More than one request can be pending at the same time. Resolve one
    /// request with ``selectPermission(_:option:)`` or with
    /// ``cancelPermission(_:)``.
    public var pendingPermissions: [PendingPermissionRequest] {
        permissions.items
    }

    /// The session-scoped elicitations that wait for the user's answer, in
    /// arrival order.
    ///
    /// More than one elicitation can be pending at the same time. Resolve one
    /// elicitation with ``acceptElicitation(_:content:)``,
    /// ``declineElicitation(_:)``, or ``cancelElicitation(_:)``.
    public var pendingElicitations: [PendingElicitation] {
        elicitations.items
    }

    // MARK: - Permissions

    /// Suspends until the user answers or cancels the permission request.
    ///
    /// The request is pending in ``pendingPermissions`` until one of these
    /// resolutions arrives:
    ///
    /// - ``selectPermission(_:option:)`` answers with the selected option.
    /// - ``cancelPermission(_:)`` and ``cancelAllPending()`` answer
    ///   `cancelled`.
    /// - Cancellation of the surrounding task answers `cancelled`. The
    ///   connection cancels that task when the agent withdraws the request,
    ///   when the turn gets cancelled, or when the transport closes.
    ///
    /// - Parameter request: The permission request from the agent.
    /// - Returns: The user's decision, or the `cancelled` outcome.
    func awaitPermissionDecision(for request: RequestPermissionRequest) async -> RequestPermissionResponse {
        await permissions.awaitResponse(to: PendingPermissionRequest(id: UUID(), request: request))
    }

    /// Answers one pending permission request with the selected option.
    ///
    /// The call removes the pending request and resolves the agent's call. A
    /// call with an unknown or already resolved id changes nothing.
    ///
    /// - Parameters:
    ///   - id: The id of the pending request.
    ///   - optionId: The id of the selected option. Give the id of one option
    ///     of the request.
    public func selectPermission(_ id: PendingPermissionRequest.ID, option optionId: PermissionOptionId) {
        permissions.resolve(id, with: PendingPermissionRequest.selectedResponse(optionId))
    }

    /// Cancels one pending permission request.
    ///
    /// The call removes the pending request and resolves the agent's call
    /// with the `cancelled` outcome, which is the spec's outcome for a request
    /// that the user did not decide. A call with an unknown or already
    /// resolved id changes nothing.
    ///
    /// - Parameter id: The id of the pending request.
    public func cancelPermission(_ id: PendingPermissionRequest.ID) {
        permissions.cancel(id)
    }

    // MARK: - Elicitations

    /// Suspends until the user answers or cancels the elicitation.
    ///
    /// The caller gives only the session-scoped elicitations of this session.
    /// The elicitation is pending in ``pendingElicitations`` until one of
    /// these resolutions arrives:
    ///
    /// - ``acceptElicitation(_:content:)`` answers with the accept action.
    /// - ``declineElicitation(_:)`` answers with the decline action.
    /// - ``completeElicitation(elicitationId:)`` answers a url-mode
    ///   elicitation with the accept action and no content.
    /// - ``cancelElicitation(_:)``, ``cancelAllPending()``, and cancellation
    ///   of the surrounding task answer with the cancel action.
    ///
    /// An elicitation that names a tool call links to the entry of that tool
    /// call while it is pending. When the entry does not exist yet, the entry
    /// takes the link when the agent adds the tool call.
    ///
    /// - Parameter request: The session-scoped elicitation from the agent.
    /// - Returns: The user's response as the spec's action object.
    func awaitElicitation(_ request: CreateElicitationRequest) async -> CreateElicitationResponse {
        let pending = PendingElicitation(id: UUID(), request: request)
        linkToToolCall(pending)
        // A resolution from the UI removes the link at once. Task cancellation
        // and a cancellation before registration remove it here.
        defer { unlinkFromToolCall(pending) }
        return await elicitations.awaitResponse(to: pending)
    }

    /// Accepts one pending elicitation.
    ///
    /// For a form-mode elicitation, give the form values as `content`; the
    /// values must match the requested schema. For a url-mode elicitation,
    /// give no content: the URL flow returns its data out of band. A call with
    /// an unknown or already resolved id changes nothing.
    ///
    /// - Parameters:
    ///   - id: The id of the pending elicitation.
    ///   - content: The form values, or `nil` for no content.
    public func acceptElicitation(_ id: PendingElicitation.ID, content: JSONValue? = nil) {
        resolveElicitation(id, with: ElicitationResponseWire.acceptResponse(content: content))
    }

    /// Declines one pending elicitation, which tells the agent that the user
    /// refused the request. A call with an unknown or already resolved id
    /// changes nothing.
    ///
    /// - Parameter id: The id of the pending elicitation.
    public func declineElicitation(_ id: PendingElicitation.ID) {
        resolveElicitation(id, with: ElicitationResponseWire.declineResponse)
    }

    /// Cancels one pending elicitation, with the spec's action for an
    /// elicitation that the user did not decide. A call with an unknown or
    /// already resolved id changes nothing.
    ///
    /// - Parameter id: The id of the pending elicitation.
    public func cancelElicitation(_ id: PendingElicitation.ID) {
        guard let removed = elicitations.cancel(id) else { return }
        unlinkFromToolCall(removed)
    }

    /// Closes the pending url-mode elicitation that an `elicitation/complete`
    /// notification names.
    ///
    /// The elicitation resolves with the accept action and no content: the URL
    /// flow returned its data out of band, so no credentials go back over ACP.
    ///
    /// - Parameter elicitationId: The elicitation id that the notification
    ///   names.
    /// - Returns: `true` when this model held a pending elicitation with that
    ///   id, `false` when nothing changed.
    func completeElicitation(elicitationId: ElicitationId) -> Bool {
        guard let pending = pendingElicitations.first(where: { $0.elicitationId == elicitationId }) else {
            return false
        }
        resolveElicitation(pending.id, with: ElicitationResponseWire.acceptResponse(content: nil))
        return true
    }

    // MARK: - Close

    /// Cancels every pending permission request and every pending
    /// elicitation.
    ///
    /// Each permission request answers `cancelled`, and each elicitation
    /// answers with the cancel action. A closed session thus leaves no pending
    /// prompt, no tool-call link, and no suspended call.
    public func cancelAllPending() {
        permissions.cancelAll()
        for id in pendingElicitations.map(\.id) {
            cancelElicitation(id)
        }
    }

    // MARK: - Tool-call links

    /// Gives a new tool-call entry the links of the pending elicitations that
    /// named its tool call before the entry existed.
    ///
    /// - Parameter entry: The new transcript entry.
    func attachUnresolvedElicitationLinks(to entry: TranscriptEntry) {
        guard case .toolCall(let toolCall) = entry,
            case .wire(.toolCall(let toolCallId)) = toolCall.id,
            let ids = unresolvedElicitationLinks.removeValue(forKey: toolCallId)
        else { return }
        toolCall.linkedElicitationIDs.append(contentsOf: ids)
    }

    /// Moves the links of each tool-call entry back to the links that wait
    /// for an entry.
    ///
    /// A transcript reset drops the entry objects. The replayed entry of the
    /// same tool call then takes the links, so a pending elicitation stays
    /// linked across the reset.
    func detachElicitationLinksFromToolCalls() {
        for case .toolCall(let entry) in wireEntries.values where !entry.linkedElicitationIDs.isEmpty {
            guard case .wire(.toolCall(let toolCallId)) = entry.id else { continue }
            unresolvedElicitationLinks[toolCallId, default: []].append(contentsOf: entry.linkedElicitationIDs)
        }
    }

    /// Resolves one pending elicitation and removes its tool-call link.
    ///
    /// - Parameters:
    ///   - id: The id of the pending elicitation.
    ///   - response: The response to resolve the agent's call with.
    private func resolveElicitation(_ id: PendingElicitation.ID, with response: CreateElicitationResponse) {
        guard let removed = elicitations.resolve(id, with: response) else { return }
        unlinkFromToolCall(removed)
    }

    /// Links a pending elicitation to the entry of the tool call it names.
    ///
    /// When that entry does not exist yet, the link waits in
    /// ``unresolvedElicitationLinks``.
    ///
    /// - Parameter elicitation: The pending elicitation.
    private func linkToToolCall(_ elicitation: PendingElicitation) {
        guard let toolCallId = elicitation.toolCallId else { return }
        guard let entry = toolCallEntry(for: toolCallId) else {
            unresolvedElicitationLinks[toolCallId, default: []].append(elicitation.id)
            return
        }
        entry.linkedElicitationIDs.append(elicitation.id)
    }

    /// Removes the link of an elicitation from the entry of its tool call, or
    /// from the links that wait for that entry.
    ///
    /// A link that is already removed changes nothing, so two calls for one
    /// elicitation are safe.
    ///
    /// - Parameter elicitation: The elicitation that resolved.
    private func unlinkFromToolCall(_ elicitation: PendingElicitation) {
        guard let toolCallId = elicitation.toolCallId else { return }
        if let entry = toolCallEntry(for: toolCallId), entry.linkedElicitationIDs.contains(elicitation.id) {
            entry.linkedElicitationIDs.removeAll { $0 == elicitation.id }
        }
        guard var waiting = unresolvedElicitationLinks[toolCallId] else { return }
        waiting.removeAll { $0 == elicitation.id }
        unresolvedElicitationLinks[toolCallId] = waiting.isEmpty ? nil : waiting
    }

    /// Finds the transcript entry of one tool call.
    ///
    /// - Parameter toolCallId: The id of the tool call.
    /// - Returns: The entry, or `nil` when the agent did not add the tool call
    ///   yet.
    private func toolCallEntry(for toolCallId: ToolCallId) -> ToolCallEntry? {
        guard case .toolCall(let entry) = wireEntries[.toolCall(toolCallId)] else { return nil }
        return entry
    }
}
