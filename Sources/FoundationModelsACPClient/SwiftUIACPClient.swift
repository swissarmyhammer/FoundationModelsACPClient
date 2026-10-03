import Foundation
import FoundationModelsACP
import Observation

/// The connection state of the client, for a UI to observe.
public enum ConnectionState: Hashable, Sendable {
    /// No transport is attached.
    case disconnected

    /// A transport is attached and serving.
    case connected
}

/// An observable ACP client container.
///
/// `SwiftUIACPClient` conforms to the wire package's `Client` protocol and
/// lands the agent's `session/update` stream in observable state, one
/// ``ACPSessionState`` per session. It depends only on the ACP wire and on
/// Observation, so SwiftUI, AppKit, and UIKit can all bind to it, and a
/// headless test can drive it.
///
/// ACP stable v2 gates elicitation behind the `elicitation` client
/// capability. This client implements both elicitation modes, so
/// ``ACPClient/advertisedCapabilities`` advertises form and url support,
/// and nothing more.
@MainActor
@Observable
public final class SwiftUIACPClient: Client {
    /// The per-session observable state, keyed by session id. The first
    /// update for a session creates its state.
    public private(set) var sessions: [SessionId: ACPSessionState] = [:]

    /// The connection state. The host that attaches a transport sets it;
    /// this lands with the transport milestone (M6).
    ///
    /// A change to ``ConnectionState/disconnected`` flushes the coalescing
    /// buffer of every session synchronously, so the last partial chunk is
    /// never left buffered when the connection closes. The same change
    /// cancels every pending permission request and every pending
    /// elicitation, so a dropped connection leaves no ghost prompt on
    /// screen and leaks no continuation.
    public var connectionState: ConnectionState = .disconnected {
        didSet {
            guard connectionState == .disconnected else { return }
            for state in sessions.values {
                state.flushPendingChunks()
                state.cancelAllPermissionRequests()
            }
            cancelAllElicitations()
        }
    }

    /// The elicitations that wait for the user's answer, in arrival order.
    ///
    /// One list holds every pending elicitation, session-scoped and
    /// request-scoped. This is the documented home decision: a
    /// request-scoped elicitation has no session, so it cannot land on a
    /// session's state, and one home also keeps one copy of the
    /// continuation lifecycle. Filter with ``pendingElicitations(for:)``
    /// for a per-session view.
    ///
    /// This is the concurrency policy: the container supports more than
    /// one outstanding elicitation at the same time. Each entry keeps its
    /// position until it resolves, and each resolves independently of the
    /// others. Resolve one elicitation with
    /// ``acceptElicitation(_:content:)``, ``declineElicitation(_:)``, or
    /// ``cancelElicitation(_:)``.
    public var pendingElicitations: [PendingElicitation] {
        elicitations.items
    }

    /// The pending elicitations and the continuation of each one. The queue
    /// is observable, so a read of ``pendingElicitations`` tracks it.
    @ObservationIgnored private let elicitations = PendingRequestQueue<PendingElicitation, CreateElicitationResponse>(
        cancelledResponse: ElicitationResponseWire.cancelResponse
    )

    /// The cadence between coalesced flushes for each session this client
    /// creates.
    private let coalescingCadence: Duration

    /// The clock that schedules the coalesced flushes.
    private let clock: any Clock<Duration>

    /// Creates a client with no sessions.
    ///
    /// - Parameters:
    ///   - coalescingCadence: The cadence between coalesced flushes for each
    ///     session this client creates.
    ///   - clock: The clock that schedules the coalesced flushes. Tests
    ///     inject a manual clock, so they do not read the wall clock.
    public init(
        coalescingCadence: Duration = ACPSessionState.defaultCoalescingCadence,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.coalescingCadence = coalescingCadence
        self.clock = clock
    }

    /// Returns the observable state for one session, and creates it when
    /// the session is new.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The session's observable state.
    public func session(for id: SessionId) -> ACPSessionState {
        if let existing = sessions[id] {
            return existing
        }
        let created = ACPSessionState(coalescingCadence: coalescingCadence, clock: clock)
        sessions[id] = created
        return created
    }

    /// Receives one streamed session update from the agent and folds it
    /// into the session's observable state.
    ///
    /// - Parameter notification: The session-update notification.
    public func sessionUpdate(_ notification: UpdateSessionNotification) async {
        session(for: notification.sessionId).apply(notification.update)
    }

    /// Answers the agent's permission request with the user's decision.
    ///
    /// The request lands as pending state on its session
    /// (``ACPSessionState/pendingPermissionRequests``), and this call
    /// suspends until the UI resolves it. A cancellation of this call —
    /// the agent withdraws the request, the turn gets cancelled, or the
    /// connection drops — clears the pending state and answers
    /// `cancelled`, which is the spec's outcome for a request the user
    /// did not decide. It never selects an option for the user.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The user's decision, or the `cancelled` outcome.
    public func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        await session(for: params.sessionId).awaitPermissionDecision(for: params)
    }

    /// Answers the agent's elicitation with the user's response.
    ///
    /// The elicitation lands as pending state in ``pendingElicitations``,
    /// and this call suspends until one of these resolutions arrives:
    ///
    /// - ``acceptElicitation(_:content:)`` resolves it with the accept
    ///   action, and with the form values when the UI gives them.
    /// - ``declineElicitation(_:)`` resolves it with the decline action.
    /// - ``cancelElicitation(_:)`` and ``cancelAllElicitations()``
    ///   resolve it with the cancel action.
    /// - ``elicitationComplete(_:)`` resolves a url-mode elicitation with
    ///   the accept action and no content.
    /// - Cancellation of the surrounding task resolves it with the cancel
    ///   action. The connection cancels that task when the agent
    ///   withdraws the elicitation, when the turn gets cancelled, or when
    ///   the transport closes.
    ///
    /// Each resolution removes the pending entry and resumes the
    /// continuation exactly one time, so no continuation leaks and no
    /// ghost prompt stays on screen.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: The user's response as the spec's action object.
    public func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        await elicitations.awaitResponse(to: PendingElicitation(id: UUID(), request: params))
    }

    /// Receives the agent's notice that a URL-based elicitation finished,
    /// and closes the matching pending prompt.
    ///
    /// The call resolves the pending url-mode elicitation whose
    /// elicitation id the notification names, with the accept action and
    /// no content: the URL flow returned its data out of band, so no
    /// credentials go back over ACP. A notification that names no pending
    /// elicitation changes nothing.
    ///
    /// - Parameter notification: The completion notification.
    public func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        guard
            let pending = pendingElicitations.first(where: {
                $0.elicitationId == notification.elicitationId
            })
        else { return }
        elicitations.resolve(pending.id, with: ElicitationResponseWire.acceptResponse(content: nil))
    }

    /// Accepts one pending elicitation.
    ///
    /// The call removes the pending entry and resolves the agent's
    /// in-flight call with the accept action. For a form-mode
    /// elicitation, give the form values as `content`; the values must
    /// match the requested schema. For a url-mode elicitation, give no
    /// content — the URL flow returns its data out of band. A call with
    /// an unknown or already resolved id changes nothing.
    ///
    /// - Parameters:
    ///   - id: The id of the pending elicitation.
    ///   - content: The form values, or `nil` for no content.
    public func acceptElicitation(_ id: UUID, content: JSONValue? = nil) {
        elicitations.resolve(id, with: ElicitationResponseWire.acceptResponse(content: content))
    }

    /// Declines one pending elicitation.
    ///
    /// The call removes the pending entry and resolves the agent's
    /// in-flight call with the decline action, which tells the agent that
    /// the user refused the request. A call with an unknown or already
    /// resolved id changes nothing.
    ///
    /// - Parameter id: The id of the pending elicitation.
    public func declineElicitation(_ id: UUID) {
        elicitations.resolve(id, with: ElicitationResponseWire.declineResponse)
    }

    /// Cancels one pending elicitation.
    ///
    /// The call removes the pending entry and resolves the agent's
    /// in-flight call with the cancel action, which is the spec's action
    /// for an elicitation the user did not decide. A call with an unknown
    /// or already resolved id changes nothing.
    ///
    /// - Parameter id: The id of the pending elicitation.
    public func cancelElicitation(_ id: UUID) {
        elicitations.cancel(id)
    }

    /// Cancels every pending elicitation.
    ///
    /// The host calls this on connection close, so a dropped connection
    /// leaves no pending prompt and leaks no continuation.
    public func cancelAllElicitations() {
        elicitations.cancelAll()
    }

    /// Returns the pending elicitations of one session, in arrival order.
    ///
    /// Request-scoped elicitations have no session, so no session filter
    /// returns them; bind to ``pendingElicitations`` for those.
    ///
    /// - Parameter sessionId: The session id to filter on.
    /// - Returns: The session's pending elicitations.
    public func pendingElicitations(for sessionId: SessionId) -> [PendingElicitation] {
        pendingElicitations.filter { $0.sessionId == sessionId }
    }
}
