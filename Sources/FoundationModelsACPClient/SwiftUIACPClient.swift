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
    public var connectionState: ConnectionState = .disconnected

    /// Creates a client with no sessions.
    public init() {}

    /// Returns the observable state for one session, and creates it when
    /// the session is new.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The session's observable state.
    public func session(for id: SessionId) -> ACPSessionState {
        if let existing = sessions[id] {
            return existing
        }
        let created = ACPSessionState()
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

    /// Answers the agent's permission request.
    ///
    /// This is a placeholder until the pending-requests milestone (M3)
    /// lands bindable permission state. It answers `cancelled`, which is
    /// the spec's outcome for a request the user did not decide. It never
    /// selects an option for the user.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The `cancelled` outcome.
    public func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .cancelled)
    }
}
