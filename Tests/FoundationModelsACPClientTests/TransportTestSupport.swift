import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

// This file holds the shared helpers for the transport tests. No helper waits
// on a clock: each wait ends on an event, a change of the observable state of
// a model or of a test store.

/// Waits until the condition is true.
///
/// The wait reads `condition` again after each change of the observable state
/// that it reads, and after each ``TestChangeSignal/post()`` of a test store
/// that is not observable. It has no clock, no poll and no time limit.
///
/// - Parameter condition: The condition to wait for.
/// - Throws: Nothing today. The signature keeps `throws`, so a call site
///   stays `try await`.
@MainActor
func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    await waitForObservation {
        _ = TestChangeSignal.shared.generation
        return condition()
    }
}

/// Waits until a session model holds an idle state.
///
/// - Parameter session: The session model.
@MainActor
func waitForIdle(of session: SessionModel) async {
    await waitForObservation {
        guard case .idle = session.agentState else { return false }
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
