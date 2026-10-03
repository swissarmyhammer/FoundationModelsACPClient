// `SessionUpdateSubscription` has no public initializer: only the connection
// makes one. The testable import reaches its memberwise initializer, so
// ``SessionModelFixtures/handMadeSubscription(hasMissedUpdates:)`` can make a
// subscription by hand.
@testable import FoundationModelsACP
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

    /// Makes a hand-made subscription and the continuation that feeds it.
    ///
    /// - Parameter hasMissedUpdates: The missed-updates mark of the subscription.
    /// - Returns: The subscription and its continuation.
    static func handMadeSubscription(
        hasMissedUpdates: Bool = false
    ) -> (SessionUpdateSubscription, AsyncStream<SessionStreamEvent>.Continuation) {
        let (events, continuation) = AsyncStream<SessionStreamEvent>.makeStream()
        return (SessionUpdateSubscription(updates: events, hasMissedUpdates: hasMissedUpdates), continuation)
    }

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

    /// Starts one permission request and waits until it is pending.
    ///
    /// - Parameters:
    ///   - model: The model that holds the request.
    ///   - request: The request to start.
    /// - Returns: The task of the agent's call.
    /// - Throws: `CancellationError` when the test time limit cancels the wait.
    @MainActor
    static func startPermission(
        on model: SessionModel,
        _ request: RequestPermissionRequest = permissionRequest()
    ) async throws -> Task<RequestPermissionResponse, Never> {
        let count = model.pendingPermissions.count
        let task = Task { await model.awaitPermissionDecision(for: request) }
        try await waitUntil { model.pendingPermissions.count == count + 1 }
        return task
    }

    // MARK: - Unstable updates

    /// The compaction id that the compaction tests use.
    static let compactionId = Unstable.CompactionId(rawValue: "compaction-1")

    /// Makes a `compaction_update` for the test compaction, as the stable
    /// update that carries it on the wire.
    ///
    /// - Parameters:
    ///   - status: The status of the compaction.
    ///   - summary: The `summary` field of the update.
    ///   - error: The `error` field of the update.
    /// - Returns: The update.
    /// - Throws: `EncodingError` when the payload does not encode.
    static func compactionUpdate(
        _ status: Unstable.CompactionStatus,
        summary: PatchField<[ContentBlock]> = .unchanged,
        error: PatchField<String> = .unchanged
    ) throws -> SessionUpdate {
        let update = Unstable.CompactionUpdate(compactionId: compactionId, status: status, error: error, summary: summary)
        return try SessionUpdate(.compactionUpdate(update))
    }

    /// Makes a `compaction_summary_chunk` for the test compaction, as the
    /// stable update that carries it on the wire.
    ///
    /// - Parameter text: The text of the summary block.
    /// - Returns: The update.
    /// - Throws: `EncodingError` when the payload does not encode.
    static func compactionChunk(_ text: String) throws -> SessionUpdate {
        let chunk = Unstable.CompactionSummaryChunk(compactionId: compactionId, content: textBlock(text))
        return try SessionUpdate(.compactionSummaryChunk(chunk))
    }

    /// Makes a `notice`, as the stable update that carries it on the wire.
    ///
    /// - Parameter notice: The notice.
    /// - Returns: The update.
    /// - Throws: `EncodingError` when the payload does not encode.
    static func noticeUpdate(_ notice: Unstable.Notice) throws -> SessionUpdate {
        try SessionUpdate(.notice(notice))
    }
}

extension SessionModel {
    /// Gives each update to ``SessionModel/apply(_:)``, in order.
    ///
    /// - Parameter updates: The updates to apply.
    func applyEach(_ updates: [SessionUpdate]) {
        for update in updates {
            apply(update)
        }
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
