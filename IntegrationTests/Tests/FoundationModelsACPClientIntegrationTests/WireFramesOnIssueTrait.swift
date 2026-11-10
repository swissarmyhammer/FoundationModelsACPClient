import Foundation
import Synchronization
import Testing

/// The connections of one test whose frames an issue of the test holds.
///
/// The ``WireFramesOnIssueTrait`` of a test makes one log, and binds it to
/// ``current`` for the test body. Each ``TraceTransport`` that the body makes
/// adds its frames to the log. The log keeps no copy of a frame: it reads the
/// recorded frames of each transport when an issue needs them.
final class WireFrameLog: Sendable {
    /// The log of the test that runs, or `nil` when the test has no
    /// ``WireFramesOnIssueTrait``.
    @TaskLocal static var current: WireFrameLog?

    /// One connection of the test: its name, and its recorded frames.
    private struct Connection {
        let name: String
        let frames: @Sendable () -> [WireFrame]
    }

    /// The connections, in the order that the test made them.
    private let connections = Mutex<[Connection]>([])

    /// Adds a connection to the log.
    ///
    /// - Parameters:
    ///   - name: The name of the connection.
    ///   - frames: Gives the recorded frames of the connection, in wire order.
    func add(connection name: String, frames: @escaping @Sendable () -> [WireFrame]) {
        connections.withLock { $0.append(Connection(name: name, frames: frames)) }
    }

    /// The text of the last frames of each connection, in the order that the
    /// test made the connections. It holds at most
    /// ``WireTraceReport/lastFrameCount`` frames for each connection.
    var lastFramesText: String {
        let all = connections.withLock { $0 }
        guard !all.isEmpty else { return "The test made no traced connection." }
        return all.flatMap { WireTraceReport.frameLines(of: $0.frames(), connection: $0.name) }
            .joined(separator: "\n")
    }
}

/// A test trait that adds the last frames of each traced connection of the
/// test to the issues of the test.
///
/// - Each issue that the test body records gets the frames as a comment.
/// - An error that the body throws is recorded as an issue with the frames.
/// - A cancel of the test, for example at its `.timeLimit`, records an issue
///   with the frames at the time of the cancel. The time-limit issue of the
///   test runner does not go through an issue handler, so this issue is a
///   separate one.
///
/// A test that passes records nothing more.
struct WireFramesOnIssueTrait: TestTrait, TestScoping {
    /// Runs the test body with a new ``WireFrameLog``.
    ///
    /// - Parameters:
    ///   - test: The test.
    ///   - testCase: The case of the test.
    ///   - function: The test body.
    /// - Throws: The error of the body after a cancel. The trait records each
    ///   other error as an issue.
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let log = WireFrameLog()
        let annotation = IssueHandlingTrait.compactMapIssues { issue in
            var annotated = issue
            annotated.comments.append(Comment(rawValue: log.lastFramesText))
            return annotated
        }
        try await WireFrameLog.$current.withValue(log) {
            try await annotation.provideScope(for: test, testCase: testCase) {
                try await withTaskCancellationHandler {
                    try await Self.recordingError(of: function, at: test.sourceLocation)
                } onCancel: {
                    Issue.record(
                        Comment(rawValue: "The test was cancelled, for example at its time limit.\n" + log.lastFramesText),
                        sourceLocation: test.sourceLocation)
                }
            }
        }
    }

    /// Runs the test body, and records its error as an issue in the scope of
    /// the issue handler, so that the issue gets the frames. After a cancel,
    /// the cancel handler recorded the frames, so the error goes to the test
    /// runner as it is.
    ///
    /// - Parameters:
    ///   - function: The test body.
    ///   - sourceLocation: The place that the issue names: the test.
    /// - Throws: The error of the body after a cancel.
    private static func recordingError(
        of function: @Sendable () async throws -> Void,
        at sourceLocation: SourceLocation
    ) async throws {
        do {
            try await function()
        } catch {
            if Task.isCancelled { throw error }
            Issue.record(error, sourceLocation: sourceLocation)
        }
    }
}

extension Trait where Self == WireFramesOnIssueTrait {
    /// The issues of the test hold the last frames of each traced connection.
    static var wireFramesOnIssue: Self {
        WireFramesOnIssueTrait()
    }
}
