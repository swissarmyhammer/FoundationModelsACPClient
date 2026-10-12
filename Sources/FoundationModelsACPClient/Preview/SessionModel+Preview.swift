import Foundation
import FoundationModelsACP

// The preview factory of `SessionModel`: a populated model with no agent and
// no connection, for a SwiftUI `#Preview` or a test of a host app. Each item
// goes through the path that a live model uses, so a preview shows the real
// state.

extension SessionModel {
    /// The id of a preview session when the caller gives no id.
    public nonisolated static let previewSessionId = SessionId(rawValue: "preview-session")

    /// The date of the wall clock of each preview model. Each entry of a
    /// preview starts at this date, and an entry that ends ends at this date
    /// too, so a preview shows the same times each time it runs.
    public nonisolated static let previewDate = Date(timeIntervalSinceReferenceDate: 0)

    /// The working directory of each sample session.
    nonisolated static let previewSampleCwd = AbsolutePath(rawValue: "/Users/preview/project")

    /// Makes a populated model of one session, with no agent and no
    /// connection.
    ///
    /// The model folds each transcript item through the merge engine that a
    /// live model uses, in order. It applies each chunk at once, and it reads
    /// a clock that never moves and the wall clock ``previewDate``, so a
    /// preview is the same each time.
    ///
    /// The model sends each request to `requestSender`, which never uses the
    /// network. Thus ``prompt(_:meta:)`` adds a user message, and its
    /// ``UserMessageEntry/sendState`` changes as it does in a live model.
    ///
    /// ```swift
    /// #Preview {
    ///     TranscriptView(session: .preview(transcript: [
    ///         .user("Why does the build fail?"),
    ///         .agent("Parser.swift does not import Foundation."),
    ///     ]))
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - cwd: The working directory of the session, or `nil` for none.
    ///   - transcript: The transcript items, in order.
    ///   - availableCommands: The commands that the agent advertises, or
    ///     `nil` when the agent did not report commands.
    ///   - configOptions: The configuration options of the session, or `nil`
    ///     when the agent did not report options.
    ///   - mcpServers: The MCP servers that the client sent. Each one gets an
    ///     item with the status ``MCPServerStatus/notReported``.
    ///   - pendingPermissions: The permission requests that wait for the
    ///     user's answer, in order. Each one is in ``pendingPermissions``
    ///     when the call returns.
    ///   - requestSender: The sender of the requests of the session.
    /// - Returns: The model.
    public static func preview(
        sessionId: SessionId = previewSessionId,
        cwd: AbsolutePath? = nil,
        transcript: [PreviewTranscriptItem] = [],
        availableCommands: [AvailableCommand]? = nil,
        configOptions: [SessionConfigOption]? = nil,
        mcpServers: [MCPServer] = [],
        pendingPermissions: [RequestPermissionRequest] = [],
        requestSender: PreviewSessionRequestSender = PreviewSessionRequestSender()
    ) -> SessionModel {
        let model = SessionModel(
            sessionId: sessionId,
            requestSender: requestSender,
            coalescingCadence: .zero,
            clock: PreviewClock(),
            now: { previewDate }
        )
        model.cwd = cwd
        model.setMCPServers(mcpServers)
        model.applyLastValues(availableCommands: availableCommands, configOptions: configOptions)
        for (position, item) in transcript.enumerated() {
            item.add(to: model, at: position)
        }
        for request in pendingPermissions {
            model.startPermissionDecision(for: request)
        }
        return model
    }

    /// A new preview model of a short conversation: a user message, a
    /// thought, an agent message, one tool call that waits, and one pending
    /// permission request for that tool call.
    public static var previewSample: SessionModel {
        preview(
            cwd: previewSampleCwd,
            transcript: [
                .user("Why does the build fail?"),
                .thought("The error names a type that Parser.swift uses but does not import."),
                .agent("Parser.swift does not import Foundation. I will add the import and run the tests."),
                .toolCall(title: "Run swift test", kind: .execute, status: .pending),
            ],
            pendingPermissions: [
                RequestPermissionRequest(
                    options: [
                        PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow")),
                        PermissionOption(kind: .rejectOnce, name: "Reject", optionId: PermissionOptionId(rawValue: "reject")),
                    ],
                    sessionId: previewSessionId,
                    title: "Run swift test?"
                )
            ]
        )
    }

    /// Folds the commands and the configuration options as the updates that
    /// an agent sends for them. An update, and not the seed of a response,
    /// keeps an empty list: an empty list means that the agent has none.
    ///
    /// - Parameters:
    ///   - availableCommands: The commands, or `nil` to leave them unreported.
    ///   - configOptions: The options, or `nil` to leave them unreported.
    private func applyLastValues(availableCommands: [AvailableCommand]?, configOptions: [SessionConfigOption]?) {
        if let availableCommands {
            apply(.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: availableCommands)))
        }
        if let configOptions {
            apply(.configOptionUpdate(ConfigOptionUpdate(configOptions: configOptions)))
        }
    }
}
