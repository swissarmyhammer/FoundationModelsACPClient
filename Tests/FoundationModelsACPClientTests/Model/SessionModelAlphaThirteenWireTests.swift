import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the wire values that schema alpha.13 added or changed and that
// the session model holds: a null request id, and the background work of an
// idle state.

/// The background work of the test idle state.
private let backgroundWork = BackgroundWork.terminal(BackgroundTerminal(terminalId: TerminalId(rawValue: "term-1")))

/// The alpha.13 wire tests, in one suite so that `swift test --filter
/// SessionModelAlphaThirteenWireTests` selects them.
@MainActor
struct SessionModelAlphaThirteenWireTests {
    @Test func aNullRequestIdMatchesItsMarkerWhenTheStartCameFirst() {
        var requests = SessionModel.ReplayRequests()

        _ = requests.didStart(.null)

        #expect(requests.didFinish(.null, outcome: .succeeded) == .succeeded)
    }

    @Test func aNullRequestIdMarkerWaitsForItsStart() {
        var requests = SessionModel.ReplayRequests()

        _ = requests.didFinish(.null, outcome: .succeeded)

        #expect(requests.didStart(.null) == .succeeded)
    }

    @Test func theAgentStateKeepsTheBackgroundWorkOfAnIdleState() {
        let model = SessionModelFixtures.immediateModel()
        let idle = StateUpdate.idle(IdleStateUpdate(background: [backgroundWork], stopReason: .endTurn))

        model.apply(.stateUpdate(idle))

        #expect(model.agentState == idle)
    }
}
