import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of a background tool call. The agent keeps a background call
// `in_progress` with `_meta.sah.backgroundRun` until the work really ends,
// and then sends the final status on the same tool call id. The model must
// show the call as busy until that final status, and must show a call that
// the agent no longer tracks as stale.

/// The raw id of the background tool call.
private let backgroundCallRawId = "background-call-1"

/// The completion token of the background run.
private let completionToken = "01M7GNYY0F8PQTNDZHG37GN77K"

/// The time between two steps of a test, in seconds.
private let step: TimeInterval = 4

/// The `_meta` value that marks a background run.
private let backgroundRunMeta: JSONValue = .object([
    "sah": .object([
        "backgroundRun": .object(["completionToken": .string(completionToken)])
    ])
])

/// The background tool call tests, in one suite so that `swift test --filter
/// BackgroundToolCallTests` selects them.
@MainActor
@Suite
struct BackgroundToolCallTests {
    /// The wall clock that gives each time.
    let wallClock = ManualWallClock()

    /// Makes a model that reads each time from ``wallClock``.
    ///
    /// - Returns: The model.
    func timedModel() -> SessionModel {
        SessionModelFixtures.makeModel(sender: FakeSessionRequestSender(), now: wallClock.now)
    }

    /// The `in_progress` update with the background run marker.
    var startedInBackground: SessionUpdate {
        .toolCallUpdate(
            ToolCallUpdate(
                toolCallId: ToolCallId(rawValue: backgroundCallRawId),
                status: .value(.inProgress),
                meta: .value(backgroundRunMeta)
            )
        )
    }

    /// Makes an idle state update with a background list.
    ///
    /// - Parameter background: The background list, or `nil` to omit it.
    /// - Returns: The update.
    func idle(background: [BackgroundWork]?) -> SessionUpdate {
        .stateUpdate(.idle(IdleStateUpdate(background: background, stopReason: .endTurn)))
    }

    /// The background list that holds the background tool call.
    var listedCall: [BackgroundWork] {
        [.toolCall(BackgroundToolCall(toolCallId: ToolCallId(rawValue: backgroundCallRawId)))]
    }

    @Test func aBackgroundCallStaysBusyUntilItsFinalStatus() throws {
        let model = timedModel()

        model.apply(startedInBackground)
        wallClock.advance(by: step)
        model.apply(idle(background: listedCall))

        let call = try #require(model.transcript.first?.toolCall)
        #expect(call.status == .inProgress)
        #expect(call.endedAt == nil)
        #expect(call.backgroundRun == completionToken)
        #expect(call.isStale == false)

        wallClock.advance(by: step)
        model.apply(toolCallStatus(id: backgroundCallRawId, .completed))

        #expect(call.status == .completed)
        #expect(call.endedAt == ManualWallClock.startDate + step + step)
        #expect(call.backgroundRun == completionToken)
        #expect(call.isStale == false)
    }

    @Test func anIdleSessionWithNoListedCallMakesTheCallStale() throws {
        let model = timedModel()

        model.apply(startedInBackground)
        model.apply(idle(background: []))

        let call = try #require(model.transcript.first?.toolCall)
        #expect(call.status == .inProgress)
        #expect(call.isStale)
    }

    @Test func anIdleStateWithNoBackgroundReportMakesTheCallStale() throws {
        let model = timedModel()

        model.apply(startedInBackground)
        model.apply(idle(background: nil))

        let call = try #require(model.transcript.first?.toolCall)
        #expect(call.isStale)
    }

    @Test func aRunningSessionKeepsTheCallBusy() throws {
        let model = timedModel()

        model.apply(startedInBackground)
        model.apply(.stateUpdate(.running(RunningStateUpdate())))

        let call = try #require(model.transcript.first?.toolCall)
        #expect(call.isStale == false)
    }

    @Test func aClosedSessionMakesTheCallStale() throws {
        let model = timedModel()

        model.apply(startedInBackground)
        model.apply(.stateUpdate(.running(RunningStateUpdate())))
        let call = try #require(model.transcript.first?.toolCall)
        #expect(call.isStale == false)

        model.markClosed()

        #expect(call.isStale)
    }

    @Test func aFinalCallIsNeverStale() throws {
        let model = timedModel()

        model.apply(startedInBackground)
        model.apply(toolCallStatus(id: backgroundCallRawId, .failed))
        model.apply(idle(background: []))

        let call = try #require(model.transcript.first?.toolCall)
        #expect(call.isStale == false)
    }

    @Test func aCallWithNoMarkerHasNoBackgroundRun() throws {
        let model = timedModel()

        model.apply(toolCallStatus(id: backgroundCallRawId, .inProgress))

        let call = try #require(model.transcript.first?.toolCall)
        #expect(call.backgroundRun == nil)
    }

    @Test func theSessionGivesTheBackgroundListOfItsState() {
        let model = timedModel()
        #expect(model.background == nil)

        model.apply(idle(background: listedCall))
        #expect(model.background == listedCall)

        model.apply(.stateUpdate(.running(RunningStateUpdate(background: []))))
        #expect(model.background == [])
    }
}
