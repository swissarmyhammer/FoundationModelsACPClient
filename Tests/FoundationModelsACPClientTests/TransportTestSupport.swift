import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// This file holds the shared helpers for the transport tests. No helper waits
// on a clock: each wait ends on an event, a change of the observable state of
// a model or of a test store.

/// Waits until the condition is true, or until the failure event comes.
///
/// The wait reads both closures again after each change of the observable
/// state that they read, and after each ``TestChangeSignal/post()`` of a test
/// store that is not observable, for example the sleepers of ``ManualClock``.
/// It has no clock and no poll. Each wait names its failure event (rule T1),
/// so a test that goes wrong fails and does not hang.
///
/// - Parameters:
///   - condition: The condition to wait for.
///   - failure: The failure event, for example the close of the connection
///     or of the session, or the end of the task that must make the change.
///   - sourceLocation: The call site, for the issue of a failed wait.
/// - Throws: ``WaitEndedOnFailure`` when the failure event came first.
@MainActor
func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    orFailWhen failure: @escaping @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitForObservation(
        until: {
            _ = TestChangeSignal.shared.generation
            return condition()
        },
        orFailWhen: failure,
        sourceLocation: sourceLocation
    )
}

/// Waits until a session model holds an idle state. The close of the
/// session is the failure event.
///
/// - Parameters:
///   - session: The session model.
///   - sourceLocation: The call site, for the issue of a failed wait.
/// - Throws: ``WaitEndedOnFailure`` when the session closed first.
@MainActor
func waitForIdle(of session: SessionModel, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    try await waitUntil(
        {
            guard case .idle = session.agentState else { return false }
            return true
        },
        orFailWhen: { session.isClosed },
        sourceLocation: sourceLocation
    )
}

extension ConnectionCloseReason {
    /// Whether the input stream of the transport finished.
    ///
    /// `ConnectionCloseReason` is not `Equatable`, because a transport failure
    /// holds `any Error`, so a test reads the case with this property.
    var isEndOfInput: Bool {
        guard case .endOfInput = self else { return false }
        return true
    }
}

/// Makes the initialize request the transport tests send.
///
/// - Returns: The request, with this package's version and capabilities.
func makeInitializeRequest() -> InitializeRequest {
    InitializeRequest(
        info: Implementation(name: "test-client", version: "1.0.0"),
        protocolVersion: ACPClient.supportedProtocolVersion,
        capabilities: ACPClient.advertisedCapabilities
    )
}
