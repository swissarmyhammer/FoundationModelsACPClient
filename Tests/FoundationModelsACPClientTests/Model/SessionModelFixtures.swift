import FoundationModelsACP

@testable import FoundationModelsACPClient

// This file holds the shared helpers of the `SessionModel` tests. Each helper
// here had a copy in more than one test file, so the copies are one helper
// now.
//
// The builders are static members of a namespace, so every function belongs
// to a type and no function stands alone at file scope.

/// The shared fixtures and model builders of the `SessionModel` tests.
enum SessionModelFixtures {
    /// The buffered cadence, in milliseconds.
    private static let bufferedCadenceMilliseconds = 40

    /// A cadence that holds chunks in the buffer until the manual clock moves
    /// or a flush runs.
    static let bufferedCadence: Duration = .milliseconds(bufferedCadenceMilliseconds)

    /// The context window that the usage fixture reports.
    private static let contextWindowSize = 200_000

    /// The used tokens that the usage fixture reports.
    private static let usedTokens = 1_500

    /// The usage report that the usage tests fold.
    static let usage = UsageUpdate(size: contextWindowSize, used: usedTokens)

    /// The "allow" option that each test permission request offers.
    static let allowOption = PermissionOption(
        kind: .allowOnce,
        name: "Allow",
        optionId: PermissionOptionId(rawValue: "allow-once")
    )

    /// The "reject" option that each test permission request offers.
    static let rejectOption = PermissionOption(
        kind: .rejectOnce,
        name: "Reject",
        optionId: PermissionOptionId(rawValue: "reject-once")
    )

    /// Makes a model for the test session that applies each chunk at once.
    ///
    /// - Returns: The model.
    @MainActor
    static func immediateModel() -> SessionModel {
        SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender(), coalescingCadence: .zero)
    }

    /// Makes a model for the test session that holds chunks in the buffer on
    /// the buffered cadence.
    ///
    /// - Parameter clock: The clock that schedules the flushes.
    /// - Returns: The model.
    @MainActor
    static func coalescingModel(clock: ManualClock) -> SessionModel {
        SessionModel(
            sessionId: testSession,
            requestSender: FakeSessionRequestSender(),
            coalescingCadence: bufferedCadence,
            clock: clock
        )
    }

    /// Makes a permission request for the test session.
    ///
    /// - Parameter title: The title of the permission prompt.
    /// - Returns: The request, with the two test options.
    static func permissionRequest(title: String = "Run the tool?") -> RequestPermissionRequest {
        RequestPermissionRequest(options: [allowOption, rejectOption], sessionId: testSession, title: title)
    }
}

extension [ContentBlock] {
    /// The text of all text blocks, joined in order.
    var joinedText: String {
        compactMap { block in
            guard case .text(let text) = block else { return nil }
            return text.text
        }
        .joined()
    }
}
