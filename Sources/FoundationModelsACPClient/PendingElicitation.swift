import Foundation
import FoundationModelsACP

/// One elicitation from the agent that waits for the user's answer.
///
/// A callback cannot be rendered, so the client turns each
/// `elicitation/create` call into this observable value. The UI binds to
/// it, shows the message and the mode payload, and resolves it through
/// ``SessionModel/acceptElicitation(_:content:)``,
/// ``SessionModel/declineElicitation(_:)``, or
/// ``SessionModel/cancelElicitation(_:)`` — or through the methods of the
/// same names on ``ConnectionModel``, which holds the request-scoped
/// elicitations.
///
/// A form-mode elicitation asks the UI to render a form from the
/// requested schema, and to accept with values that match that schema. A
/// url-mode elicitation asks the UI to direct the user to ``url``. The
/// models never navigate on their own: the UI must show ``targetHost``,
/// get the user's consent, and only then navigate. The URL flow returns
/// its data out of band, and the `elicitation/complete` notification of the
/// agent closes the prompt, so no credentials go back over ACP.
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

    /// The wire method of the client request that this elicitation names, or
    /// `nil`.
    ///
    /// Only a request-scoped elicitation that ``ConnectionModel`` holds has a
    /// method, for example `auth/login`, so the UI can show which operation
    /// asked. The model reads the method when the elicitation arrives.
    public let requestMethod: String?

    /// Makes a pending elicitation.
    ///
    /// - Parameters:
    ///   - id: The local identity of the pending elicitation.
    ///   - request: The request as the agent sent it.
    ///   - requestMethod: The wire method of the client request that the
    ///     elicitation names, or `nil` when it names no request.
    init(id: UUID, request: CreateElicitationRequest, requestMethod: String? = nil) {
        self.id = id
        self.request = request
        self.requestMethod = requestMethod
    }

    /// The session this elicitation is tied to, or `nil`.
    ///
    /// A request-scoped elicitation has no session — it can arrive before
    /// any session exists, for example during authentication. The
    /// ``ConnectionModel`` holds such an elicitation, and the
    /// ``SessionModel`` of this session holds each other one.
    public var sessionId: SessionId? {
        sessionScope?.sessionId
    }

    /// The tool call this elicitation is tied to, or `nil`.
    ///
    /// Only a session-scoped elicitation can name a tool call. The session
    /// model links the elicitation to the transcript entry of that tool call
    /// while the elicitation is pending.
    public var toolCallId: ToolCallId? {
        sessionScope?.toolCallId
    }

    /// The JSON-RPC request this elicitation is tied to, or `nil`.
    ///
    /// Only a request-scoped elicitation has a request id; a session-scoped
    /// elicitation gives `nil`.
    public var requestId: RequestId? {
        guard case .request(let scope) = request.elicitationScope else { return nil }
        return scope.requestId
    }

    /// The session scope of the request, or `nil` for another scope.
    private var sessionScope: ElicitationSessionScope? {
        guard case .session(let scope) = request.elicitationScope else { return nil }
        return scope
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

/// The wire keys, the action values, and the action objects of a
/// `CreateElicitationResponse`.
///
/// The wire package models `CreateElicitationResponse` as raw JSON in this
/// schema revision, so this client builds the spec's action objects itself,
/// from these named members. Each owner of pending elicitations answers with
/// these objects, so the objects exist one time.
enum ElicitationResponseWire {
    /// The key of the action member.
    static let actionKey = "action"

    /// The key of the accepted-content member.
    static let contentKey = "content"

    /// The action value of an accepted elicitation.
    static let acceptAction = "accept"

    /// The action value of a declined elicitation.
    static let declineAction = "decline"

    /// The action value of a cancelled elicitation.
    static let cancelAction = "cancel"

    /// The decline action object.
    static let declineResponse: CreateElicitationResponse = .object([
        actionKey: .string(declineAction)
    ])

    /// The cancel action object.
    static let cancelResponse: CreateElicitationResponse = .object([
        actionKey: .string(cancelAction)
    ])

    /// Makes the accept action object, with the content when it is given.
    ///
    /// - Parameter content: The form values, or `nil` for no content.
    /// - Returns: The accept action object.
    static func acceptResponse(content: JSONValue?) -> CreateElicitationResponse {
        var members: [String: JSONValue] = [actionKey: .string(acceptAction)]
        if let content {
            members[contentKey] = content
        }
        return .object(members)
    }
}

/// The scope of an elicitation, read from either mode.
///
/// The form mode and the url mode each declare their own scope type with the
/// same two cases, so one value holds both. A mode that this schema revision
/// does not know carries no scope that the client can read.
enum ElicitationScope: Sendable {
    /// The elicitation is tied to a session, and possibly to a tool call.
    case session(ElicitationSessionScope)

    /// The elicitation is tied to one JSON-RPC request.
    case request(ElicitationRequestScope)

    /// The elicitation has a mode that the client does not know, with this
    /// wire name.
    case unknownMode(String)
}

extension CreateElicitationRequest {
    /// The scope of the request, read from its mode.
    var elicitationScope: ElicitationScope {
        switch mode {
        case .form(let form):
            switch form.scope {
            case .session(let scope): .session(scope)
            case .request(let scope): .request(scope)
            }
        case .url(let urlMode):
            switch urlMode.scope {
            case .session(let scope): .session(scope)
            case .request(let scope): .request(scope)
            }
        case .unknown(let name, _):
            .unknownMode(name)
        }
    }
}

extension PendingRequestQueue where Item == PendingElicitation, Response == CreateElicitationResponse {
    /// Closes the pending url-mode elicitation that an `elicitation/complete`
    /// notification names.
    ///
    /// The elicitation resolves with the accept action and no content: the URL
    /// flow returned its data out of band, so no credentials go back over ACP.
    /// Each owner of pending elicitations closes them through this method, so
    /// the match and the answer exist one time.
    ///
    /// - Parameter elicitationId: The elicitation id that the notification
    ///   names.
    /// - Returns: The closed elicitation, or `nil` when no pending
    ///   elicitation has that id.
    @discardableResult
    func complete(elicitationId: ElicitationId) -> PendingElicitation? {
        guard let pending = items.first(where: { $0.elicitationId == elicitationId }) else { return nil }
        return resolve(pending.id, with: ElicitationResponseWire.acceptResponse(content: nil))
    }
}
