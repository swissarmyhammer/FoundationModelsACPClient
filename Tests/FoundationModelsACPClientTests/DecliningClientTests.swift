import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient
@testable import AcpClientCore

// These tests cover `DecliningClient`, the headless policy of the binary: a
// batch run has nobody at the keyboard, so every request that waits on a
// person is refused at once, and each refusal writes one line to standard
// error.
//
// Both packages export a type called `TerminalOutput`, and this file imports
// both, so the binary's terminal layer is named `AcpClientCore.TerminalOutput`
// in full. The wire package's `TerminalOutput` is the ACP model of an
// agent-owned terminal, and it has no part in these tests.
//
// Every test builds the layer over a buffer sink, so the assertions read the
// bytes the layer wrote and the test process never touches the real standard
// error.
//
// The elicitation requests come from `ElicitationFixtures`, which the
// elicitation tests of the models share.

/// The "allow" option that the permission requests here offer.
private let allowOption = PermissionOption(
    kind: .allowOnce,
    name: "Allow",
    optionId: PermissionOptionId(rawValue: "allow-once")
)

/// The "reject this time" option that the permission requests here offer.
private let rejectOnceOption = PermissionOption(
    kind: .rejectOnce,
    name: "Reject",
    optionId: PermissionOptionId(rawValue: "reject-once")
)

/// The "reject and remember" option that the permission requests here offer.
private let rejectAlwaysOption = PermissionOption(
    kind: .rejectAlways,
    name: "Reject always",
    optionId: PermissionOptionId(rawValue: "reject-always")
)

/// The title that the permission requests here carry.
private let permissionTitle = "Run the tool?"

/// The command that a command-subject permission request names.
private let permissionCommand = "swift build"

/// Makes a permission request for the test session.
///
/// - Parameters:
///   - options: The options the request offers.
///   - subject: The operation the request asks about, or `nil` for none.
/// - Returns: The request.
private func permissionRequest(
    options: [PermissionOption],
    subject: RequestPermissionSubject? = nil
) -> RequestPermissionRequest {
    RequestPermissionRequest(
        options: options,
        sessionId: testSession,
        title: permissionTitle,
        subject: subject
    )
}

/// The subject text a refusal line carries when the request names no
/// subject: the request's title, quoted.
private let titleSubjectText = "\"\(permissionTitle)\""

/// The mode text a refusal line carries for a form-mode elicitation.
private let formModeText = "form"

/// The mode text a refusal line carries for a url-mode elicitation.
private let urlModeText = "url"

/// The whole response the binary gives to every elicitation, in both modes.
private let declineResponse: CreateElicitationResponse = .object([
    "action": .string("decline")
])

/// The line the binary writes when it refuses one permission request.
///
/// - Parameter subject: The subject text the line names.
/// - Returns: The whole line, with its terminator.
private func permissionRefusalLine(subject: String) -> String {
    "declined session/request_permission for \(subject)\n"
}

/// The line the binary writes when it refuses one elicitation.
///
/// - Parameter mode: The mode text the line names.
/// - Returns: The whole line, with its terminator.
private func elicitationRefusalLine(mode: String) -> String {
    "declined elicitation/create for \(mode) mode\n"
}

/// The `Client` a ``DecliningClient`` stands in front of in these tests.
///
/// It records each call that reaches it. A permission request or an
/// elicitation that reached it gets an answer that grants, so a wrapper that
/// forwarded one would give the agent something no person saw, and the
/// assertions on the refusal would fail.
private struct RecordingInnerClient: Client {
    /// Each session update that reached this client, in arrival order.
    let sessionUpdates = ThreadSafeBuffer<UpdateSessionNotification>()

    /// The id of each elicitation-completion notice that reached this client,
    /// in arrival order.
    let completedElicitations = ThreadSafeBuffer<ElicitationId>()

    /// The wire method of each request that reached this client, in arrival
    /// order.
    let requests = ThreadSafeBuffer<String>()

    /// Records the update.
    ///
    /// - Parameter notification: The session-update notification.
    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        sessionUpdates.append(notification)
    }

    /// Records the request and grants it with the allow option.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The allow outcome.
    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        requests.append(ClientMethodName.requestPermission)
        return RequestPermissionResponse(
            outcome: .selected(SelectedPermissionOutcome(optionId: allowOption.optionId))
        )
    }

    /// Records the request and accepts it.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: The accept action.
    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        requests.append(ClientMethodName.createElicitation)
        return .object(["action": .string("accept")])
    }

    /// Records the id of the finished elicitation.
    ///
    /// - Parameter notification: The completion notification.
    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        completedElicitations.append(notification.elicitationId)
    }
}

/// The wire names of the two requests ``RecordingInnerClient`` records.
private enum ClientMethodName {
    /// The permission request.
    static let requestPermission = "session/request_permission"

    /// The elicitation request.
    static let createElicitation = "elicitation/create"
}

/// Builds the terminal layer of a test over a buffer sink.
///
/// - Parameters:
///   - verbosity: The verbosity to build the layer with.
///   - buffer: The buffer that stands for standard error.
/// - Returns: The layer.
private func bufferedTerminal(
    verbosity: TerminalVerbosity,
    into buffer: ThreadSafeBuffer<String>
) -> AcpClientCore.TerminalOutput {
    AcpClientCore.TerminalOutput(
        verbosity: verbosity,
        isStandardErrorATerminal: { false },
        sink: { buffer.append($0) }
    )
}

/// A ``DecliningClient`` in front of a recording client and over a buffer
/// sink.
///
/// The buffer stands for standard error, so the assertions read bytes. The
/// injected terminal reading is always `false`: a test process cannot make
/// its own standard error a terminal, and the refusal lines do not depend on
/// that reading.
@MainActor
private struct DecliningClientHarness {
    /// The client the declining client stands in front of.
    let inner = RecordingInnerClient()

    /// Everything the terminal layer wrote, in the chunks the sink received.
    let buffer = ThreadSafeBuffer<String>()

    /// The value under test.
    let client: DecliningClient

    /// Builds the client in front of a fresh recording client and over a
    /// fresh buffer.
    ///
    /// - Parameter verbosity: The verbosity to build the terminal layer with.
    init(verbosity: TerminalVerbosity = .normal) {
        client = DecliningClient(inner: inner, output: bufferedTerminal(verbosity: verbosity, into: buffer))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPermissionRequestWithARejectOptionIsAnsweredWithThatOption() async throws {
    let harness = DecliningClientHarness()

    let response = try await harness.client.requestPermission(
        permissionRequest(options: [allowOption, rejectOnceOption])
    )

    #expect(
        response.outcome == .selected(SelectedPermissionOutcome(optionId: rejectOnceOption.optionId))
    )
    // The request never reached the inner client, so no prompt waits for a
    // person who is not there.
    #expect(harness.inner.requests.elements.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPermissionRequestWithNoRejectOptionIsAnsweredCancelled() async throws {
    let harness = DecliningClientHarness()

    let response = try await harness.client.requestPermission(
        permissionRequest(options: [allowOption])
    )

    #expect(response.outcome == .cancelled)
    #expect(harness.inner.requests.elements.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPermissionRequestPrefersTheRejectionThatIsNotRemembered() async throws {
    let harness = DecliningClientHarness()

    // The options list offers the remembered rejection first, so the answer
    // proves a choice and not a position.
    let response = try await harness.client.requestPermission(
        permissionRequest(options: [rejectAlwaysOption, rejectOnceOption])
    )

    #expect(
        response.outcome == .selected(SelectedPermissionOutcome(optionId: rejectOnceOption.optionId))
    )
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPermissionRefusalNamesTheToolCallItRefused() async throws {
    let harness = DecliningClientHarness()
    let toolCallID = ToolCallId(rawValue: "fs-read-1")

    _ = try await harness.client.requestPermission(
        permissionRequest(
            options: [allowOption, rejectOnceOption],
            subject: .toolCall(ToolCallPermissionSubject(toolCall: ToolCallUpdate(toolCallId: toolCallID)))
        )
    )

    #expect(harness.buffer.text == permissionRefusalLine(subject: "tool call \(toolCallID.rawValue)"))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPermissionRefusalNamesTheCommandItRefused() async throws {
    let harness = DecliningClientHarness()
    let cwd = AbsolutePath(rawValue: "/")

    _ = try await harness.client.requestPermission(
        permissionRequest(
            options: [allowOption, rejectOnceOption],
            subject: .command(CommandPermissionSubject(command: permissionCommand, cwd: cwd))
        )
    )

    #expect(harness.buffer.text == permissionRefusalLine(subject: "command \"\(permissionCommand)\""))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPermissionRefusalNamesTheTitleWhenTheRequestCarriesNoSubject() async throws {
    let harness = DecliningClientHarness()

    _ = try await harness.client.requestPermission(
        permissionRequest(options: [allowOption, rejectOnceOption])
    )

    #expect(harness.buffer.text == permissionRefusalLine(subject: titleSubjectText))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aFormElicitationIsDeclinedAtOnce() async throws {
    let harness = DecliningClientHarness()
    let request = ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))

    let response = try await harness.client.createElicitation(request)

    #expect(response == declineResponse)
    #expect(harness.buffer.text == elicitationRefusalLine(mode: formModeText))
    // The elicitation never reached the inner client, so no prompt waits for
    // a person who is not there.
    #expect(harness.inner.requests.elements.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aUrlElicitationIsDeclinedWithNoURLOpenedAndNoValueSentBack() async throws {
    let harness = DecliningClientHarness()
    let request = ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))

    let response = try await harness.client.createElicitation(request)

    // The whole object is the decline action. It carries no "content"
    // member, so no credential goes back over ACP.
    #expect(response == declineResponse)
    #expect(harness.buffer.text == elicitationRefusalLine(mode: urlModeText))
    #expect(harness.inner.requests.elements.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSessionUpdateIsForwardedToTheInnerClient() async throws {
    let harness = DecliningClientHarness()
    let update = agentChunk(text: "Hello from the agent.", message: "declining-agent-msg-1")

    await harness.client.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))

    #expect(harness.inner.sessionUpdates.elements.map(\.sessionId) == [testSession])
    #expect(harness.inner.sessionUpdates.elements.map(\.update) == [update])
    // Forwarding writes nothing: only a refusal writes a line.
    #expect(harness.buffer.elements.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anElicitationCompleteIsForwardedToTheInnerClient() async throws {
    let harness = DecliningClientHarness()

    await harness.client.elicitationComplete(
        CompleteElicitationNotification(elicitationId: ElicitationFixtures.urlID)
    )

    #expect(harness.inner.completedElicitations.elements == [ElicitationFixtures.urlID])
    #expect(harness.buffer.elements.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func eachRefusalWritesOneLineAtQuietToo() async throws {
    let harness = DecliningClientHarness(verbosity: .quiet)
    let request = ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))

    _ = try await harness.client.requestPermission(
        permissionRequest(options: [allowOption, rejectOnceOption])
    )
    _ = try await harness.client.createElicitation(request)

    #expect(
        harness.buffer.text
            == permissionRefusalLine(subject: titleSubjectText)
                + elicitationRefusalLine(mode: formModeText)
    )
}

/// The refusal lines belong to standard error, and §8 keeps standard output
/// for the answer text alone. This scan is the byte-level proof: a buffer
/// sink cannot see a byte that went straight to file descriptor 1, so the
/// source itself must name no way to reach it.
@Test func theDecliningClientNamesNoWayToWriteToStandardOutput() throws {
    let source = try RepositoryFile.read(
        relativePath: "Sources/AcpClientCore/DecliningClient.swift"
    )
    for name in ["print(", "standardOutput", "STDOUT_FILENO", "fputs", "fwrite"] {
        #expect(!source.contains(name), "DecliningClient.swift names \"\(name)\".")
    }
}

/// The connection model serves the declining client in front of its own
/// router, so the elicitation of a turn is refused at once, no model holds it
/// as pending, and the turn still reaches its stop reason.
@MainActor @Test(.timeLimit(.minutes(1)))
func anElicitationDuringATurnStillLetsTheTurnReachItsStopReason() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let idle = idleState(stopReason: .endTurn)
    let agentConnection = await AgentSideConnection(stream: agentEnd) { agentSide in
        ScriptedStubAgent(
            connection: agentSide,
            session: testSession,
            script: [idle],
            elicitation: ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))
        )
    }
    let buffer = ThreadSafeBuffer<String>()
    let terminal = bufferedTerminal(verbosity: .normal, into: buffer)
    let model = ConnectionModel(coalescingCadence: .zero)
    let connection = await model.connect(over: clientEnd) { router in
        DecliningClient(inner: router, output: terminal)
    }
    let session = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: "/")))
    var updates = session.updateTap().makeAsyncIterator()

    // The prompt returns only after the agent's elicitation was answered, so
    // a wrapper that waited for a person would time this test out.
    _ = try await session.prompt([textBlock("go")])

    #expect(await updates.next() == idle)
    #expect(session.pendingElicitations.isEmpty)
    #expect(model.pendingElicitations.isEmpty)
    #expect(buffer.text == elicitationRefusalLine(mode: formModeText))

    await connection.close()
    withExtendedLifetime(agentConnection) {}
}
