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
// container's own elicitation tests share.

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

/// A ``DecliningClient`` over a real container and a buffer sink.
///
/// The buffer stands for standard error, so the assertions read bytes. The
/// injected terminal reading is always `false`: a test process cannot make
/// its own standard error a terminal, and the refusal lines do not depend on
/// that reading.
@MainActor
private struct DecliningClientHarness {
    /// The container the client stands in front of.
    let container: SwiftUIACPClient

    /// Everything the terminal layer wrote, in the chunks the sink received.
    let buffer: ThreadSafeBuffer<String>

    /// The value under test.
    let client: DecliningClient

    /// Builds the client over a fresh container and a fresh buffer.
    ///
    /// - Parameter verbosity: The verbosity to build the terminal layer with.
    init(verbosity: TerminalVerbosity = .normal) {
        let buffer = ThreadSafeBuffer<String>()
        let container = SwiftUIACPClient()
        self.buffer = buffer
        self.container = container
        client = DecliningClient(
            container: container,
            output: AcpClientCore.TerminalOutput(
                verbosity: verbosity,
                isStandardErrorATerminal: { false },
                sink: { buffer.append($0) }
            )
        )
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
    // The request never reached the container, so no prompt waits for a
    // person who is not there.
    #expect(harness.container.session(for: testSession).pendingPermissionRequests.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPermissionRequestWithNoRejectOptionIsAnsweredCancelled() async throws {
    let harness = DecliningClientHarness()

    let response = try await harness.client.requestPermission(
        permissionRequest(options: [allowOption])
    )

    #expect(response.outcome == .cancelled)
    #expect(harness.container.session(for: testSession).pendingPermissionRequests.isEmpty)
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
    let cwd = try #require(AbsolutePath(rawValue: "/"))

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
    // The elicitation never reached the container, so no prompt waits for a
    // person who is not there.
    #expect(harness.container.pendingElicitations.isEmpty)
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
    #expect(harness.container.pendingElicitations.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aForwardedSessionUpdateLandsInTheContainersSessionState() async throws {
    let harness = DecliningClientHarness()
    let messageID = MessageId(rawValue: "declining-agent-msg-1")
    let replyText = "Hello from the agent."

    await harness.client.sessionUpdate(
        UpdateSessionNotification(
            sessionId: testSession,
            update: agentChunk(text: replyText, message: messageID.rawValue)
        )
    )

    let state = harness.container.session(for: testSession)
    state.flushPendingChunks()
    #expect(state.messageContent(for: messageID) == [textBlock(replyText)])
    // Forwarding writes nothing: only a refusal writes a line.
    #expect(harness.buffer.elements.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aForwardedElicitationCompleteReachesTheContainer() async throws {
    let harness = DecliningClientHarness()
    let request = ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))

    // The container is the only holder of pending elicitations, so the
    // request goes to it directly. A resolution proves the notification
    // reached it through the wrapper.
    let responseTask = Task { try await harness.container.createElicitation(request) }
    try await waitUntil { !harness.container.pendingElicitations.isEmpty }

    await harness.client.elicitationComplete(
        CompleteElicitationNotification(elicitationId: ElicitationFixtures.urlID)
    )

    let response = try await responseTask.value
    #expect(response == .object(["action": .string("accept")]))
    #expect(harness.container.pendingElicitations.isEmpty)
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

@MainActor @Test(.timeLimit(.minutes(1)))
func anElicitationDuringATurnStillLetsTheTurnReachItsStopReason() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let elicitation = ElicitationFixtures.formRequest(
        scope: .session(ElicitationFixtures.sessionScope)
    )
    let agentConnection = await AgentSideConnection(stream: agentEnd) { agentSide in
        ScriptedStubAgent(
            connection: agentSide,
            session: testSession,
            script: [idleState(stopReason: .endTurn)],
            elicitation: elicitation
        )
    }
    let harness = DecliningClientHarness()
    let connection = await harness.container.connect(over: clientEnd) { _ in harness.client }

    let cwd = try #require(AbsolutePath(rawValue: "/"))
    let session = try await connection.newSession(NewSessionRequest(cwd: cwd))
    #expect(session.sessionId == testSession)

    // The prompt returns only after the agent's elicitation was answered, so
    // a wrapper that waited for a person would time this test out.
    _ = try await connection.prompt(
        PromptRequest(prompt: [textBlock("go")], sessionId: session.sessionId)
    )

    let state = harness.container.session(for: session.sessionId)
    #expect(await eventually { state.lastStopReason == .endTurn })
    #expect(harness.container.pendingElicitations.isEmpty)
    #expect(harness.buffer.text == elicitationRefusalLine(mode: formModeText))

    await connection.close()
    withExtendedLifetime(agentConnection) {}
}
