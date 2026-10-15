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

    @Test func theCapabilitiesOfEachUserPresence() {
        // A host with a user advertises the same value as before.
        #expect(ACPClient.capabilities(for: .interactive) == ACPClient.advertisedCapabilities)

        // A host with no user advertises no `elicitation` capability, so a
        // conforming agent sends no question that would wait for ever.
        let headless = ACPClient.capabilities(for: .headless)
        #expect(headless.elicitation == nil)
        #expect(headless.auth == nil)
        #expect(headless == ClientCapabilities())
    }

    @Test func theNoUserReasonIsTheTextOfExtras() {
        // FoundationModelsExtras `RunPlane.noUserPresentReason` has the same
        // text, so each layer reports the same words.
        #expect(ACPClient.noUserPresentReason == "no user is present")
        #expect(ACPClient.elicitationReasonMetaKey == "reason")
    }
}
