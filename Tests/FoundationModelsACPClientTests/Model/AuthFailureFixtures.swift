@testable import FoundationModelsACPClient

// This file holds the auth failures that more than one auth test file
// expects. The initialize tests and the terminal auth tests each had a copy
// of the unsupported-failure construction, so the copies are one helper now.
// Each test file keeps its own per-case failures, and builds them from this
// helper.

/// The shared auth failures of the auth tests of the connection model.
enum AuthFailureFixtures {
    /// The failure that an auth operation records when the model refuses it
    /// as unsupported.
    ///
    /// - Parameters:
    ///   - operation: The auth operation that the model refuses.
    ///   - method: The ACP wire method of the operation, or
    ///     ``ConnectionModelError/terminalAuthOperation`` for a terminal
    ///     login.
    /// - Returns: The failure of `operation`, with the unsupported reason of
    ///   `method`.
    static func unsupportedFailure(of operation: AuthFailure.Operation, method: String) -> AuthFailure {
        AuthFailure(operation: operation, reason: .unsupported(method: method))
    }
}
