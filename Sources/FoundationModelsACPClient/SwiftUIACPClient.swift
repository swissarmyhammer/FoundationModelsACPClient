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
/// ACP stable v2 defines no capability-gated client method: `sessionUpdate`
/// and `requestPermission` are the whole client surface. This client
/// therefore advertises nothing it does not implement.
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
    /// cancels every pending permission request, so a dropped connection
    /// leaves no ghost prompt on screen and leaks no continuation.
    public var connectionState: ConnectionState = .disconnected {
        didSet {
            guard connectionState == .disconnected else { return }
            for state in sessions.values {
                state.flushPendingChunks()
                state.cancelAllPermissionRequests()
            }
        }
    }

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
}
