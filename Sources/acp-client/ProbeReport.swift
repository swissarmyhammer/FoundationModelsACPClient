import Foundation
import FoundationModelsACP

// `ProbeReport` — what `acp-client probe` says about an agent (`cli-plan.md`
// §6), in the two forms §6.1 asks for: the plain text, and the `--json` form.
//
// The value holds no I/O of its own, so the whole rendering is decided here and
// `ProbeCommand` is left with the process, the handshake and one write.
//
// Three decisions in this file are not free choices.
//
// 1. **The commands carry three states, not a list.** An agent that is slow and
//    an agent that runs no command both leave the list empty, and a report that
//    printed one text for both would state something the run never learned.
//    ``ProbeSlashCommands`` is that distinction, and ``ProbeSlashCommands/
//    reported(_:)`` is the one place an empty list becomes the second state.
// 2. **The plain form writes no JSON.** §6.1 gives `--json` its own flag, so a
//    reader who did not ask for JSON reads labelled sections, and a script that
//    did gets the whole report as one object.
// 3. **The capabilities render as their wire paths.** `AgentCapabilities` is a
//    tree of optional marker structs, and an advertised capability is a member
//    that is present rather than a value that is true. So the report names the
//    dotted path of each present marker — `session.prompt.image` — which is the
//    spelling a person compares against the agent's own documentation. A
//    capability the schema adds later needs one line in the path functions at
//    the foot of this file, and nothing else in the file reads that tree.

/// The slash commands one `probe` read, or the reason it read none.
///
/// The three cases are three different facts, and `cli-plan.md` §6 keeps them
/// apart on purpose: a list, an agent that reported no command at all, and a
/// wait that ended before the agent reported anything.
enum ProbeSlashCommands: Codable, Hashable, Sendable {
    /// The agent reported these commands.
    case listed([AvailableCommand])

    /// The agent reported its command list, and the list was empty.
    case reportedNone

    /// The bounded wait ended before the agent reported its command list.
    ///
    /// The agent may still have commands. This case says the run does not know,
    /// and `probe` still exits 0, because the agent answered.
    case waitEndedFirst

    /// Reads the state of a command list the agent reported.
    ///
    /// This is the one place an empty report becomes ``reportedNone``, so no
    /// caller can build a ``listed(_:)`` that carries nothing.
    ///
    /// - Parameter commands: The commands the agent reported.
    /// - Returns: ``listed(_:)`` for a list that holds a command, and
    ///   ``reportedNone`` for one that holds none.
    static func reported(_ commands: [AvailableCommand]) -> ProbeSlashCommands {
        commands.isEmpty ? .reportedNone : .listed(commands)
    }

    /// The members of the JSON form of this value.
    private enum CodingKeys: String, CodingKey {
        /// Which of the three states the report carries.
        case state

        /// The commands, written for ``listed(_:)`` alone.
        case commands
    }

    /// The name each state carries in the JSON form.
    ///
    /// The names are spelled out rather than derived, because a script reads
    /// them and a renamed case must not silently rename a JSON value.
    private enum State: String, Codable {
        /// ``ProbeSlashCommands/listed(_:)``.
        case listed

        /// ``ProbeSlashCommands/reportedNone``.
        case reportedNone

        /// ``ProbeSlashCommands/waitEndedFirst``.
        case waitEndedFirst
    }

    /// Decodes one command state from its JSON form.
    ///
    /// - Parameter decoder: The decoder positioned at the object.
    /// - Throws: `DecodingError` when the state is missing or unknown, or when
    ///   a listed state carries no commands.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .listed:
            self = .listed(try container.decode([AvailableCommand].self, forKey: .commands))
        case .reportedNone:
            self = .reportedNone
        case .waitEndedFirst:
            self = .waitEndedFirst
        }
    }

    /// Encodes one command state as its JSON form.
    ///
    /// - Parameter encoder: The encoder to write the object into.
    /// - Throws: Rethrows any error from the underlying encoder.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .listed(let commands):
            try container.encode(State.listed, forKey: .state)
            try container.encode(commands, forKey: .commands)
        case .reportedNone:
            try container.encode(State.reportedNone, forKey: .state)
        case .waitEndedFirst:
            try container.encode(State.waitEndedFirst, forKey: .state)
        }
    }
}

/// What one agent reports about itself (`cli-plan.md` §6).
///
/// The four parts are the four things §6 names: the protocol version, the agent
/// capabilities, the authentication methods, and the slash commands. Three come
/// out of the `initialize` answer; the fourth arrives as an
/// `available_commands_update` on the session, which is why `probe` opens a
/// session and why ``slashCommands`` carries three states rather than a list.
///
/// The `Codable` conformance IS the `--json` form of §6.1, and
/// ``plainText()`` is the form a reader gets without the flag.
struct ProbeReport: Codable, Hashable, Sendable {
    /// The protocol version the agent answered `initialize` with.
    let protocolVersion: ProtocolVersion

    /// The capabilities the agent advertised.
    let capabilities: AgentCapabilities

    /// The authentication methods the agent advertised.
    ///
    /// `InitializeResponse.authMethods` is optional on the wire, and an omitted
    /// list and an empty list mean the same thing: the agent advertises no
    /// authentication method. So this member is never optional, and the report
    /// says "none" for both.
    let authMethods: [AuthMethod]

    /// The slash commands the agent reported, or the reason it reported none.
    let slashCommands: ProbeSlashCommands

    /// The text that stands before a part that holds nothing the agent
    /// advertised.
    ///
    /// §6 asks the report to SAY a part is empty. A section that printed
    /// nothing would read as a report that forgot the part.
    private static let advertisedNoneLine = "the agent advertised none"

    /// The indent each item of a section carries.
    private static let itemIndent = "  "

    /// The label of the slash-command section.
    private static let commandsLabel = "slash commands"

    /// The line the slash-command section carries for an agent that reported
    /// its command list, and reported no command in it.
    private static let reportedNoCommandLine = "the agent reported none"

    /// The line the slash-command section carries for an agent that reported
    /// no command list before the wait ended.
    ///
    /// It is not ``reportedNoCommandLine``, and that is the whole point: the
    /// two say different things about the agent, and `cli-plan.md` §6 asks the
    /// report to keep them apart.
    private static let waitEndedFirstLine =
        "the agent sent no command list before the wait ended"

    /// Renders the report as the labelled text a reader gets without `--json`.
    ///
    /// Each part is a labelled section, and an empty part carries one line that
    /// says it is empty. The text carries no terminator: the caller decides
    /// what follows it.
    ///
    /// - Returns: The report text, without a trailing newline.
    func plainText() -> String {
        let sections = [
            "protocol version: \(protocolVersion.rawValue)",
            Self.section(
                "agent capabilities",
                items: Self.capabilityPaths(in: capabilities),
                emptyLine: Self.advertisedNoneLine
            ),
            Self.section(
                "authentication methods",
                items: authMethods.map(Self.line(for:)),
                emptyLine: Self.advertisedNoneLine
            ),
            Self.commandSection(for: slashCommands),
        ]
        return sections.joined(separator: "\n")
    }

    /// Renders the report as the JSON form of `--json`.
    ///
    /// The keys are sorted, so two runs against one agent give one text and a
    /// reader can compare them line by line. The text carries no terminator,
    /// for the reason ``plainText()`` states.
    ///
    /// - Returns: The report as one line of JSON.
    /// - Throws: The encoding failure, which no report this binary builds can
    ///   produce, because every part of it comes off the wire as JSON already.
    func jsonText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Renders one labelled section of the plain text.
    ///
    /// - Parameters:
    ///   - label: The name of the part.
    ///   - items: The lines of the part, without their indent.
    ///   - emptyLine: The line to write when the part holds nothing.
    /// - Returns: The section, without a trailing newline.
    private static func section(
        _ label: String,
        items: [String],
        emptyLine: String
    ) -> String {
        let lines = items.isEmpty ? [emptyLine] : items
        return ([label + ":"] + lines.map { itemIndent + $0 }).joined(separator: "\n")
    }

    /// Renders the slash-command section of the plain text.
    ///
    /// The two empty states carry different lines, which is the whole reason
    /// ``ProbeSlashCommands`` has three cases: a reader must be able to tell an
    /// agent that runs no command from an agent that did not answer in time.
    ///
    /// - Parameter commands: The command state the report carries.
    /// - Returns: The section, without a trailing newline.
    private static func commandSection(for commands: ProbeSlashCommands) -> String {
        switch commands {
        case .listed(let listed):
            section(commandsLabel, items: listed.map(line(for:)), emptyLine: reportedNoCommandLine)
        case .reportedNone:
            section(commandsLabel, items: [], emptyLine: reportedNoCommandLine)
        case .waitEndedFirst:
            section(commandsLabel, items: [], emptyLine: waitEndedFirstLine)
        }
    }

    /// Renders one authentication method as a line of the plain text.
    ///
    /// A method this build does not know still stands in the report, named by
    /// the discriminator the agent sent: `probe` says what the agent reports,
    /// and dropping a method would say the agent reported fewer.
    ///
    /// - Parameter method: The method the agent advertised.
    /// - Returns: The line, without its indent.
    private static func line(for method: AuthMethod) -> String {
        switch method {
        case .agent(let agent):
            "\(agent.methodId.rawValue): \(agent.name)"
        case .terminal(let terminal):
            "\(terminal.methodId.rawValue): \(terminal.name)"
        case .unknown(let discriminator, _):
            "\(discriminator): an authentication method this build does not know"
        }
    }

    /// Renders one slash command as a line of the plain text.
    ///
    /// - Parameter command: The command the agent reported.
    /// - Returns: The line, without its indent.
    private static func line(for command: AvailableCommand) -> String {
        "\(command.name): \(command.description)"
    }

    /// Names each capability the agent advertised, in the dotted spelling of
    /// the wire schema.
    ///
    /// An advertised capability is a member that is PRESENT, and each present
    /// member is an object that can carry further members, so the answer is a
    /// path and not a name. A capability the schema adds later gets one line
    /// here; nothing else in this file reads the capability tree.
    ///
    /// - Parameter capabilities: The capabilities the agent advertised.
    /// - Returns: The paths, in the order the schema declares them.
    private static func capabilityPaths(in capabilities: AgentCapabilities) -> [String] {
        path("auth", ifAdvertised: capabilities.auth)
            + (capabilities.session.map(sessionCapabilityPaths) ?? [])
    }

    /// Names each session capability the agent advertised.
    ///
    /// - Parameter session: The session capabilities the agent advertised.
    /// - Returns: The paths, in the order the schema declares them.
    private static func sessionCapabilityPaths(in session: SessionCapabilities) -> [String] {
        ["session"]
            + path("session.additionalDirectories", ifAdvertised: session.additionalDirectories)
            + path("session.delete", ifAdvertised: session.delete)
            + (session.mcp.map(mcpCapabilityPaths) ?? [])
            + (session.prompt.map(promptCapabilityPaths) ?? [])
    }

    /// Names each MCP capability the agent advertised.
    ///
    /// - Parameter mcp: The MCP capabilities the agent advertised.
    /// - Returns: The paths, in the order the schema declares them.
    private static func mcpCapabilityPaths(in mcp: MCPCapabilities) -> [String] {
        ["session.mcp"]
            + path("session.mcp.http", ifAdvertised: mcp.http)
            + path("session.mcp.stdio", ifAdvertised: mcp.stdio)
    }

    /// Names each prompt capability the agent advertised.
    ///
    /// - Parameter prompt: The prompt capabilities the agent advertised.
    /// - Returns: The paths, in the order the schema declares them.
    private static func promptCapabilityPaths(in prompt: PromptCapabilities) -> [String] {
        ["session.prompt"]
            + path("session.prompt.audio", ifAdvertised: prompt.audio)
            + path("session.prompt.embeddedContext", ifAdvertised: prompt.embeddedContext)
            + path("session.prompt.image", ifAdvertised: prompt.image)
    }

    /// Names one capability when the agent advertised it.
    ///
    /// - Parameters:
    ///   - name: The dotted path of the capability.
    ///   - marker: The member the agent either sent or left out.
    /// - Returns: The path, or nothing when the member is absent.
    private static func path<Marker>(_ name: String, ifAdvertised marker: Marker?) -> [String] {
        marker == nil ? [] : [name]
    }
}
