// `DecliningClient` — the headless policy of `cli-plan.md`: a batch run has
// nobody at the keyboard, so every request that waits on a person is refused
// at once.
//
// The binary sends `ACPClient.advertisedCapabilities`, which advertises
// elicitation in both modes, so a foreign agent may send
// `session/request_permission` or `elicitation/create` in the middle of the
// one turn. `SwiftUIACPClient` answers both by holding the request as
// observable pending state until a UI resolves it, and there is no UI here.
// A container left to answer would therefore hang the turn for ever.
//
// So this file stands one `Client` in front of the container, through the
// `connect(over:logger:client:)` seam. The two notifications forward
// unchanged, because the connection delivers each of them one time and a
// wrapper that swallows either one leaves the container's observable state
// stale. The two requests never reach the container at all: they are refused
// here and answered at once.
//
// Each refusal writes one line through `TerminalOutput.error(_:)`, so
// `--quiet` shows it too. That is a deliberate exception to §8's "a default
// run writes nothing to stderr until it fails": a run that refused an agent
// something must say what it refused, or the person who reads the transcript
// cannot tell a refusal from an answer the agent never asked for.
//
// One name to watch. `FoundationModelsACP` exports a `TerminalOutput` of its
// own — the ACP model of what an agent-owned terminal printed. Inside this
// target the local type wins the lookup, and the local type is the one this
// file means.

import FoundationModelsACP
import FoundationModelsACPClient

/// The `Client` a headless run serves, standing in front of the observable
/// container.
///
/// ``sessionUpdate(_:)`` and ``elicitationComplete(_:)`` forward to the
/// container unchanged, so the observable state is exactly what it would be
/// with no wrapper at all.
///
/// ``requestPermission(_:)`` and ``createElicitation(_:)`` never forward.
/// Each returns a refusal at once and writes one line to standard error, so
/// the turn keeps running and a batch run never grants an agent something a
/// person did not see.
@MainActor
final class DecliningClient: Client {
    /// The observable container this client stands in front of.
    private let container: SwiftUIACPClient

    /// The terminal layer that receives the refusal lines.
    private let output: TerminalOutput

    /// The wire name of the permission request this client refuses.
    private static let permissionMethod = "session/request_permission"

    /// The wire name of the elicitation request this client refuses.
    private static let elicitationMethod = "elicitation/create"

    /// The key of the action member of a `CreateElicitationResponse`.
    private static let elicitationActionKey = "action"

    /// The action value that refuses an elicitation.
    private static let elicitationDeclineAction = "decline"

    /// The whole response to every elicitation, in both modes.
    ///
    /// The wire package models `CreateElicitationResponse` as raw JSON in
    /// this schema revision, so the spec's action object is built here from
    /// named members. The object holds the action and nothing else: it
    /// carries no `content` member, so no value the agent asked for ever
    /// goes back over ACP.
    private static let declineResponse: CreateElicitationResponse = .object([
        elicitationActionKey: .string(elicitationDeclineAction)
    ])

    /// Creates the headless client.
    ///
    /// - Parameters:
    ///   - container: The observable container to stand in front of.
    ///   - output: The terminal layer that receives the refusal lines.
    init(container: SwiftUIACPClient, output: TerminalOutput) {
        self.container = container
        self.output = output
    }

    /// Forwards one streamed session update to the container.
    ///
    /// - Parameter notification: The session-update notification.
    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        await container.sessionUpdate(notification)
    }

    /// Refuses the agent's permission request, and says so on standard
    /// error.
    ///
    /// The request never reaches the container. The answer is the request's
    /// own rejection option when it offers one, and the `cancelled` outcome
    /// when it offers none — that outcome is the spec's result for a request
    /// the user did not decide.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The refusal outcome.
    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        output.error(
            Self.refusalLine(method: Self.permissionMethod, subject: Self.subjectText(of: params))
        )
        guard let rejection = Self.rejectionOption(among: params.options) else {
            return RequestPermissionResponse(outcome: .cancelled)
        }
        return RequestPermissionResponse(
            outcome: .selected(SelectedPermissionOutcome(optionId: rejection.optionId))
        )
    }

    /// Refuses the agent's elicitation, and says so on standard error.
    ///
    /// The elicitation never reaches the container, in form mode and in url
    /// mode alike. A url-mode elicitation is refused without navigating: no
    /// URL is opened, and no credential goes back over ACP.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: The decline action object.
    func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        output.error(
            Self.refusalLine(method: Self.elicitationMethod, subject: Self.modeText(of: params.mode))
        )
        return Self.declineResponse
    }

    /// Forwards the agent's elicitation-completion notice to the container.
    ///
    /// - Parameter notification: The completion notification.
    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await container.elicitationComplete(notification)
    }

    /// Builds the one line a refusal writes.
    ///
    /// - Parameters:
    ///   - method: The wire name of the method that was refused.
    ///   - subject: What was refused, already in its display form.
    /// - Returns: The line, without a terminator.
    private static func refusalLine(method: String, subject: String) -> String {
        "declined \(method) for \(subject)"
    }

    /// Names what a permission request asked to do.
    ///
    /// The subject is optional on the wire, so a request that carries none
    /// is named by its title instead. Free text is quoted and an identifier
    /// is not, so a reader can tell one from the other.
    ///
    /// - Parameter request: The permission request.
    /// - Returns: The subject text of the refusal line.
    private static func subjectText(of request: RequestPermissionRequest) -> String {
        guard let subject = request.subject else {
            return quoted(request.title)
        }
        switch subject {
        case .toolCall(let toolCallSubject):
            return "tool call \(toolCallSubject.toolCall.toolCallId.rawValue)"
        case .command(let commandSubject):
            return "command \(quoted(commandSubject.command))"
        case .unknown(let discriminator, _):
            return "subject \(quoted(discriminator))"
        }
    }

    /// Names the mode an elicitation asked for.
    ///
    /// - Parameter mode: The mode payload of the elicitation request.
    /// - Returns: The mode text of the refusal line.
    private static func modeText(of mode: CreateElicitationRequest.Payload) -> String {
        switch mode {
        case .form:
            return "form mode"
        case .url:
            return "url mode"
        case .unknown(let discriminator, _):
            return "\(quoted(discriminator)) mode"
        }
    }

    /// Chooses the option that refuses a permission request.
    ///
    /// A rejection that is not remembered wins over one that is. A headless
    /// run answers this one request; it does not set a standing policy on
    /// the agent for a person who never saw the prompt.
    ///
    /// - Parameter options: The options the request offers.
    /// - Returns: The rejection option, or `nil` when the request offers
    ///   none.
    private static func rejectionOption(among options: [PermissionOption]) -> PermissionOption? {
        options.first { $0.kind == .rejectOnce } ?? options.first { $0.kind == .rejectAlways }
    }

    /// Wraps free text in double quotes, so a reader can see where it ends.
    ///
    /// - Parameter text: The text to wrap.
    /// - Returns: The quoted text.
    private static func quoted(_ text: String) -> String {
        "\"\(text)\""
    }
}
