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

    /// The client capabilities that this client sends during `initialize`.
    ///
    /// The client advertises only the modes it implements, and nothing
    /// more. ``SwiftUIACPClient`` implements both elicitation modes: form
    /// mode as bindable pending state that the UI answers with
    /// schema-shaped values, and url mode as pending state with a
    /// consent-gated URL that `elicitation/complete` closes. The value
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
    /// terminal builds its own `ClientCapabilities` value, and handles the
    /// `terminal` authentication method itself.
    public static let advertisedCapabilities = ClientCapabilities(
        elicitation: ElicitationCapabilities(
            form: ElicitationFormCapabilities(),
            url: ElicitationUrlCapabilities()
        )
    )
}
