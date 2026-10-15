import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The shared answer helpers of the telemetry tests. `ContentSafetyTests` and
// `AgentRequestSpanRoutingTests` answer the permission requests and the
// elicitations of the agent through the `SessionModel` of the turn, as a user
// does. The two suites use these helpers, so the answer flow has one copy.

/// One answer that the user gives to an elicitation, and the outcome that the
/// span of the elicitation records for it.
enum ElicitationAnswer: CaseIterable, Sendable {
    /// The user accepts the elicitation, with the form values.
    case accept

    /// The user declines the elicitation.
    case decline

    /// The user cancels the elicitation.
    case cancel

    /// The form value that the user gives when the user accepts a form
    /// elicitation.
    ///
    /// Rule 4 of the OpenTelemetry design: no span, log record or metric
    /// holds form content. `ContentSafetyTests` forbids this text.
    static let formValue = "Accepted form value: the jade harbor"

    /// The form values that the user accepts a form elicitation with. They
    /// hold `formValue` as the one required "name" field.
    static let formContent: JSONValue = .object(["name": .string(formValue)])

    /// The outcome that the span records for this answer.
    var outcome: String {
        switch self {
        case .accept: ACPClientTelemetry.OutcomeValue.accept
        case .decline: ACPClientTelemetry.OutcomeValue.decline
        case .cancel: ACPClientTelemetry.OutcomeValue.cancel
        }
    }

    /// Waits until the session holds a pending elicitation, and gives this
    /// answer to the first one.
    ///
    /// - Parameter session: The session model that holds the elicitation.
    /// - Throws: The error of `#require`.
    @MainActor
    func give(in session: SessionModel) async throws {
        let pending = try await UserAnswers.firstPendingElicitation(of: session)
        switch self {
        case .accept: session.acceptElicitation(pending.id, content: Self.formContent)
        case .decline: session.declineElicitation(pending.id)
        case .cancel: session.cancelElicitation(pending.id)
        }
    }
}

/// The answers that the user gives to the pending permission requests of a
/// session, and the waits for the pending requests.
@MainActor
enum UserAnswers {
    /// Waits until the session holds a pending permission request, and gives
    /// the first one.
    ///
    /// - Parameter session: The session model of the turn.
    /// - Returns: The first pending permission request.
    /// - Throws: The error of `#require`.
    static func firstPendingPermission(of session: SessionModel) async throws -> PendingPermissionRequest {
        try await waitUntil { !session.pendingPermissions.isEmpty }
        return try #require(session.pendingPermissions.first)
    }

    /// Waits until the session holds a pending elicitation, and gives the
    /// first one.
    ///
    /// - Parameter session: The session model of the turn.
    /// - Returns: The first pending elicitation.
    /// - Throws: The error of `#require`.
    static func firstPendingElicitation(of session: SessionModel) async throws -> PendingElicitation {
        try await waitUntil { !session.pendingElicitations.isEmpty }
        return try #require(session.pendingElicitations.first)
    }

    /// Waits until the session holds a pending permission request, and
    /// selects one option of it.
    ///
    /// - Parameters:
    ///   - option: The id of the option that the user selects.
    ///   - session: The session model of the turn.
    /// - Throws: The error of `#require`.
    static func selectPermission(_ option: PermissionOptionId, in session: SessionModel) async throws {
        let pending = try await firstPendingPermission(of: session)
        await session.selectPermission(pending.id, option: option)
    }

    /// Waits until the session holds a pending permission request, and
    /// cancels it.
    ///
    /// - Parameter session: The session model of the turn.
    /// - Throws: The error of `#require`.
    static func cancelPermission(in session: SessionModel) async throws {
        let pending = try await firstPendingPermission(of: session)
        await session.cancelPermission(pending.id)
    }
}
