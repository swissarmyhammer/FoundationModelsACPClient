import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of `ACPClient`: the values that each host of this package sends in
// its `initialize` request.

/// The `ACPClient` tests, in one suite so that `swift test --filter
/// ACPClientTests` selects them.
struct ACPClientTests {
    @Test func advertisedCapabilitiesMatchTheImplementedMethods() {
        // ACP stable v2 gates elicitation behind the `elicitation` capability
        // field. The models implement both elicitation modes, so the client
        // advertises form and url support, and nothing more.
        let expected = ClientCapabilities(
            elicitation: ElicitationCapabilities(
                form: ElicitationFormCapabilities(),
                url: ElicitationUrlCapabilities()
            )
        )
        #expect(ACPClient.advertisedCapabilities == expected)

        // The vendored `schema-v2.0.0-alpha.3` added the `auth` capability
        // field. This client keeps that field omitted: `AgentProcess` spawns
        // the agent on pipes, thus this client cannot run the agent invocation
        // again in an interactive terminal. The omitted field tells the agent
        // to put no `terminal` entry in its `authMethods`.
        #expect(ACPClient.advertisedCapabilities.auth == nil)
    }
}
