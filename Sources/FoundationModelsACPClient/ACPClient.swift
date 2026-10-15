import FoundationModelsACP

/// A namespace for package-level facts about this ACP client.
///
/// This package implements the ACP Client role. It depends only on the ACP
/// wire (`FoundationModelsACP`) and on Observation. It must not depend on the
/// agent runtime or on a view framework; a test enforces that boundary.
public enum ACPClient {
    /// The ACP protocol version that this client supports and sends during
    /// `initialize`.
    public static let supportedProtocolVersion: ProtocolVersion = .v2

    /// Tells whether a user is present to answer the questions of the agent.
    ///
    /// The host sets it when it builds the capabilities of `initialize` with
    /// ``capabilities(for:)``. A host with a UI is ``interactive``. A host
    /// with no UI, for example a command-line run with no terminal prompt, is
    /// ``headless``.
    public enum UserPresence: Sendable, Hashable {
        /// A user is present. The client advertises both elicitation modes,
        /// and each elicitation becomes pending state that the UI answers.
        case interactive

        /// No user is present. The client advertises no `elicitation`
        /// capability, and answers each elicitation at once with `cancel`
        /// and the reason ``ACPClient/noUserPresentReason``.
        case headless
    }

    /// The reason of the `cancel` that ``ConnectionModel`` gives at once to an
    /// elicitation when the last `initialize` sent no `elicitation`
    /// capability. The text is the same as the reason of the headless cancel
    /// in FoundationModelsExtras, so each layer reports the same words.
    public static let noUserPresentReason = "no user is present"

    /// The reason of the `cancel` that ``ConnectionModel`` gives at once to an
    /// elicitation whose mode the last `initialize` did not advertise, when
    /// it advertised the other mode.
    public static let unadvertisedElicitationModeReason = "the client did not advertise this elicitation mode"

    /// The key of the reason in the `_meta` object of an elicitation
    /// response.
    ///
    /// The ACP elicitation response has no reason field, so a `cancel` that
    /// the client gives without the user carries its reason as
    /// `"_meta": {"reason": "<text>"}`. The key is stable; an agent can read
    /// it.
    public static let elicitationReasonMetaKey = "reason"

    /// The client capabilities for the given user presence.
    ///
    /// - ``UserPresence/interactive`` gives the `elicitation` capability with
    ///   `form` and `url`, the same value as ``advertisedCapabilities``.
    /// - ``UserPresence/headless`` gives no `elicitation` capability, so a
    ///   conforming agent sends no question that would wait for ever.
    ///
    /// Both values omit the `auth` capability; see
    /// ``advertisedCapabilities``.
    ///
    /// - Parameter presence: Whether a user is present.
    /// - Returns: The capabilities to send in `initialize`.
    public static func capabilities(for presence: UserPresence) -> ClientCapabilities {
        switch presence {
        case .interactive: advertisedCapabilities
        case .headless: ClientCapabilities()
        }
    }

    /// The client capabilities that this client sends during `initialize`
    /// when a user is present: the same value as
    /// ``capabilities(for:)`` with ``UserPresence/interactive``. A host with
    /// no UI uses ``capabilities(for:)`` with ``UserPresence/headless``.
    ///
    /// The client advertises only the modes it implements, and nothing
    /// more. ``SessionModel`` and ``ConnectionModel`` implement both
    /// elicitation modes: form mode as bindable pending state that the UI
    /// answers with schema-shaped values, and url mode as pending state with
    /// a consent-gated URL that `elicitation/complete` closes. The value
    /// therefore advertises the `elicitation` capability with `form` and
    /// `url`.
    ///
    /// The value omits the `auth` capability, and that omission is a
    /// decision. A client advertises `auth.terminal` only when it can run
    /// the configured agent invocation again in an interactive terminal.
    /// ``AgentProcess`` spawns the agent with `posix_spawn` on pipes, which
    /// gives the user no terminal to type into. An omitted `auth` field
    /// tells the agent to put no `terminal` entry in its `authMethods`, so
    /// this client never has such a method to run. A host that does own a
    /// terminal builds its own `ClientCapabilities` value with
    /// `auth.terminal`, and runs a `terminal` authentication method through
    /// ``ConnectionModel/loginWithTerminal(_:runner:)`` with a
    /// ``TerminalAuthRunner`` of its own.
    public static let advertisedCapabilities = ClientCapabilities(
        elicitation: ElicitationCapabilities(
            form: ElicitationFormCapabilities(),
            url: ElicitationUrlCapabilities()
        )
    )
}
