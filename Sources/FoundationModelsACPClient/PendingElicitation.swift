import Foundation
import FoundationModelsACP

/// One elicitation from the agent that waits for the user's answer.
///
/// A callback cannot be rendered, so the client turns each
/// `elicitation/create` call into this observable value. The UI binds to
/// it, shows the message and the mode payload, and resolves it through
/// ``SwiftUIACPClient/acceptElicitation(_:content:)``,
/// ``SwiftUIACPClient/declineElicitation(_:)``, or
/// ``SwiftUIACPClient/cancelElicitation(_:)``.
///
/// A form-mode elicitation asks the UI to render a form from the
/// requested schema, and to accept with values that match that schema. A
/// url-mode elicitation asks the UI to direct the user to ``url``. The
/// container never navigates on its own: the UI must show ``targetHost``,
/// get the user's consent, and only then navigate. The URL flow returns
/// its data out of band, and
/// ``SwiftUIACPClient/elicitationComplete(_:)`` closes the prompt, so no
/// credentials go back over ACP.
///
/// The wire request carries no local identity of its own, so the client
/// gives each pending elicitation a local, stable identity. SwiftUI
/// `ForEach` uses that identity, and the resolution calls use it to name
/// one elicitation.
public struct PendingElicitation: Identifiable, Hashable, Sendable {
    /// The local identity of the pending elicitation.
    public let id: UUID

    /// The request as the agent sent it. It carries the message, the
    /// mode payload, and the scope, so the UI can show what the agent
    /// asks for.
    public let request: CreateElicitationRequest

    /// The session this elicitation is tied to, or `nil`.
    ///
    /// A request-scoped elicitation has no session — it can arrive before
    /// any session exists, for example during authentication.
    /// ``SwiftUIACPClient/pendingElicitations(for:)`` filters on this
    /// value.
    public var sessionId: SessionId? {
        switch request.mode {
        case .form(let form):
            switch form.scope {
            case .session(let scope): scope.sessionId
            case .request: nil
            }
        case .url(let urlMode):
            switch urlMode.scope {
            case .session(let scope): scope.sessionId
            case .request: nil
            }
        case .unknown:
            nil
        }
    }

    /// The elicitation id, or `nil`.
    ///
    /// Only the url mode carries an elicitation id. The agent's
    /// `elicitation/complete` notification names it.
    public var elicitationId: ElicitationId? {
        guard case .url(let urlMode) = request.mode else { return nil }
        return urlMode.elicitationId
    }

    /// The URL a url-mode elicitation directs the user to, or `nil` for
    /// another mode or for a string that is not a valid URL.
    public var url: URL? {
        guard case .url(let urlMode) = request.mode else { return nil }
        return URL(string: urlMode.url)
    }

    /// The host of ``url``, or `nil`.
    ///
    /// This is the consent obligation: the UI must show this host and
    /// get the user's consent before it navigates.
    public var targetHost: String? {
        url?.host()
    }
}
