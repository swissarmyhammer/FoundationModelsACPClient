// `SessionUpdateSubscription` has no public initializer: only the connection
// makes one. The testable import reaches its memberwise initializer, so
// ``SessionModelFixtures/handMadeSubscription(hasMissedUpdates:)`` can make a
// subscription by hand.
import Foundation
@testable import FoundationModelsACP
@testable import FoundationModelsACPClient

// This file holds the shared helpers of the `SessionModel` tests. Each helper
// here had a copy in more than one test file, so the copies are one helper
// now.
//
// The builders are static members of a namespace, so every function belongs
// to a type and no function stands alone at file scope.

extension Array where Element: AnyObject {
    /// The object identity of each element, in order. Two lists with equal
    /// identities hold the same instances in the same order.
    var identities: [ObjectIdentifier] {
        map(ObjectIdentifier.init)
    }
}

/// The shared fixtures and model builders of the `SessionModel` tests.
enum SessionModelFixtures {
    /// The buffered cadence, in milliseconds.
    private static let bufferedCadenceMilliseconds = 40

    /// A cadence that holds chunks in the buffer until the manual clock moves
    /// or a flush runs.
    static let bufferedCadence: Duration = .milliseconds(bufferedCadenceMilliseconds)

    /// The cursor of a replay of the whole retained history.
    static let replayFromStart: ReplayFrom = .start(ReplayFromStart())

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

    /// Makes a model for the test session that sends its requests through
    /// the given fake sender.
    ///
    /// - Parameters:
    ///   - sender: The fake sender of the model.
    ///   - cadence: The coalescing cadence of the model. `.zero` applies each
    ///     chunk at once.
    ///   - clock: The clock that schedules the coalesced flushes.
    ///   - now: The wall clock that gives the time of each transcript entry.
    ///   - logger: The diagnostic sink of the model.
    /// - Returns: The model.
    @MainActor
    static func makeModel(
        sender: FakeSessionRequestSender,
        cadence: Duration = .zero,
        clock: ManualClock = ManualClock(),
        now: @escaping @Sendable () -> Date = Date.init,
        logger: ACPLogger = .disabled
    ) -> SessionModel {
        SessionModel(
            sessionId: testSession,
            requestSender: sender,
            coalescingCadence: cadence,
            clock: clock,
            now: now,
            logger: logger
        )
    }

    /// Makes a model for the test session that applies each chunk at once.
    ///
    /// - Returns: The model.
    @MainActor
    static func immediateModel() -> SessionModel {
        makeModel(sender: FakeSessionRequestSender())
    }

    /// Makes a model for the test session that holds chunks in the buffer on
    /// the buffered cadence.
    ///
    /// - Parameter clock: The clock that schedules the flushes.
    /// - Returns: The model.
    @MainActor
    static func coalescingModel(clock: ManualClock) -> SessionModel {
        makeModel(sender: FakeSessionRequestSender(), cadence: bufferedCadence, clock: clock)
    }

    /// Makes a permission request for the test session.
    ///
    /// - Parameter title: The title of the permission prompt.
    /// - Returns: The request, with the two test options.
    static func permissionRequest(title: String = "Run the tool?") -> RequestPermissionRequest {
        RequestPermissionRequest(options: [allowOption, rejectOption], sessionId: testSession, title: title)
    }

    /// Starts one permission request. The request is pending when the call
    /// returns.
    ///
    /// - Parameters:
    ///   - model: The model that holds the request.
    ///   - request: The request to start.
    /// - Returns: The task of the agent's call.
    @MainActor
    static func startPermission(
        on model: SessionModel,
        _ request: RequestPermissionRequest = permissionRequest()
    ) -> Task<RequestPermissionResponse, Never> {
        model.startPermissionDecision(for: request)
    }

    // MARK: - Compaction and notice updates

    /// The compaction id that the compaction tests use.
    static let compactionId = CompactionId(rawValue: "compaction-1")

    /// Makes a `compaction_update` for the test compaction.
    ///
    /// - Parameters:
    ///   - status: The status of the compaction.
    ///   - summary: The `summary` field of the update.
    ///   - error: The `error` field of the update.
    /// - Returns: The update.
    static func compactionUpdate(
        _ status: CompactionStatus,
        summary: PatchField<[ContentBlock]> = .unchanged,
        error: PatchField<String> = .unchanged
    ) -> SessionUpdate {
        let update = CompactionUpdate(compactionId: compactionId, status: status, error: error, summary: summary)
        return .compactionUpdate(update)
    }

    /// Makes a `compaction_summary_chunk` for the test compaction.
    ///
    /// - Parameter text: The text of the summary block.
    /// - Returns: The update.
    static func compactionChunk(_ text: String) -> SessionUpdate {
        let chunk = CompactionSummaryChunk(compactionId: compactionId, content: textBlock(text))
        return .compactionSummaryChunk(chunk)
    }

    /// Makes a `notice` update.
    ///
    /// - Parameter notice: The notice.
    /// - Returns: The update.
    static func noticeUpdate(_ notice: Notice) -> SessionUpdate {
        .notice(notice)
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

    /// Starts a prompt of one text block, and waits until the fake sender
    /// holds the request.
    ///
    /// - Parameters:
    ///   - text: The text of the prompt.
    ///   - sender: The fake sender of this model.
    ///   - meta: The `_meta` of the prompt request, or `nil` for none.
    /// - Returns: The task of the prompt call.
    func startPrompt(
        _ text: String,
        heldBy sender: FakeSessionRequestSender,
        meta: JSONValue? = nil
    ) async -> Task<PromptResponse, any Error> {
        let call = Task { try await prompt([textBlock(text)], meta: meta) }
        var received = sender.receivedPrompts.makeAsyncIterator()
        _ = await received.next()
        return call
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
