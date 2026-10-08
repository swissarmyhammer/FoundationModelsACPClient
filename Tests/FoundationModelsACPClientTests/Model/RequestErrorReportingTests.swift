import FoundationModelsACP
import Testing

import FoundationModelsACPClient

// The tests of the public API that gives the error entry of a failed request:
// `RequestError.init(reporting:)` and `SessionModel.appendError(reporting:)`.
// This file uses a plain import, not `@testable`, as a host outside the client
// package does. Thus the file compiles only when the two APIs are public.

/// The message of the entry for a connection that closed before the answer.
private let closedMessage = "The connection to the agent closed before the agent answered."

/// The message of the entry for a request that timed out before the answer.
private let timedOutMessage = "The request timed out before the agent answered."

/// The `data` of the entry for a closed connection.
private let closedData: JSONValue = .object(["connectionError": .string("closed")])

/// The `data` of the entry for a time-out.
private let timedOutData: JSONValue = .object(["connectionError": .string("timedOut")])

/// The tests of the public error-report API, in one suite so that
/// `swift test --filter RequestErrorReportingTests` selects them.
@MainActor
struct RequestErrorReportingTests {
    @Test func reportOfAClosedConnectionHasTheClientTextAndData() {
        let report = RequestError(reporting: ConnectionError.closed)

        #expect(report.code == .internalError)
        #expect(report.message == closedMessage)
        #expect(report.data == closedData)
    }

    @Test func reportOfATimeOutHasTheClientTextAndData() {
        let report = RequestError(reporting: ConnectionError.timedOut)

        #expect(report.code == .internalError)
        #expect(report.message == timedOutMessage)
        #expect(report.data == timedOutData)
    }

    @Test func appendErrorReportingAClosedConnectionAddsTheEntry() throws {
        let model = SessionModelFixtures.immediateModel()

        model.appendError(reporting: ConnectionError.closed)

        let entry = try #require(model.transcript.last?.error)
        #expect(entry.origin == .local)
        #expect(entry.code == .internalError)
        #expect(entry.message == closedMessage)
        #expect(entry.data == closedData)
    }

    @Test func appendErrorReportingATimeOutAddsTheEntry() throws {
        let model = SessionModelFixtures.immediateModel()

        model.appendError(reporting: ConnectionError.timedOut)

        let entry = try #require(model.transcript.last?.error)
        #expect(entry.origin == .local)
        #expect(entry.code == .internalError)
        #expect(entry.message == timedOutMessage)
        #expect(entry.data == timedOutData)
    }
}
