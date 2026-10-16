import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The shared answer helpers of the telemetry tests. `ContentSafetyTests` and
// `AgentRequestSpanRoutingTests` answer the permission requests and the
// elicitations of the agent through the `SessionModel` of the turn, as a user
// does. The two suites use these helpers, so the answer flow has one copy.
//
// Each wait for a pending request ends also on the end of the turn: when the
// prompt ended or the session closed, the agent asks for nothing more, so the
// request never comes (rule T1).

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

    /// Waits until the session of the turn holds a pending elicitation, and
    /// gives this answer to the first one.
    ///
    /// - Parameter turn: The running turn whose session holds the
    ///   elicitation.
    /// - Throws: The error of `#require`, or ``WaitEndedOnFailure`` when the
    ///   turn ended before the elicitation came.
    @MainActor
    func give(in turn: RunningTurn) async throws {
        let session = turn.session
        let pending = try await UserAnswers.firstPendingElicitation(of: turn)
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
    /// Waits until the session of the turn holds a pending permission
    /// request, and gives the first one.
    ///
    /// - Parameter turn: The running turn.
    /// - Returns: The first pending permission request.
    /// - Throws: The error of `#require`, or ``WaitEndedOnFailure`` when the
    ///   turn ended before the request came.
    static func firstPendingPermission(of turn: RunningTurn) async throws -> PendingPermissionRequest {
        let session = turn.session
        try await waitUntil { !session.pendingPermissions.isEmpty } orFailWhen: { turn.hasEnded }
        return try #require(session.pendingPermissions.first)
    }

    /// Waits until the session of the turn holds a pending elicitation, and
    /// gives the first one.
    ///
    /// - Parameter turn: The running turn.
    /// - Returns: The first pending elicitation.
    /// - Throws: The error of `#require`, or ``WaitEndedOnFailure`` when the
    ///   turn ended before the elicitation came.
    static func firstPendingElicitation(of turn: RunningTurn) async throws -> PendingElicitation {
        let session = turn.session
        try await waitUntil { !session.pendingElicitations.isEmpty } orFailWhen: { turn.hasEnded }
        return try #require(session.pendingElicitations.first)
    }

    /// Waits until the session of the turn holds a pending permission
    /// request, and selects one option of it.
    ///
    /// - Parameters:
    ///   - option: The id of the option that the user selects.
    ///   - turn: The running turn.
    /// - Throws: The error of `#require`, or ``WaitEndedOnFailure`` when the
    ///   turn ended before the request came.
    static func selectPermission(_ option: PermissionOptionId, in turn: RunningTurn) async throws {
        let pending = try await firstPendingPermission(of: turn)
        await turn.session.selectPermission(pending.id, option: option)
    }

    /// Waits until the session of the turn holds a pending permission
    /// request, and cancels it.
    ///
    /// - Parameter turn: The running turn.
    /// - Throws: The error of `#require`, or ``WaitEndedOnFailure`` when the
    ///   turn ended before the request came.
    static func cancelPermission(in turn: RunningTurn) async throws {
        let pending = try await firstPendingPermission(of: turn)
        await turn.session.cancelPermission(pending.id)
    }
}
