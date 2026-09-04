import Foundation
import FoundationModelsACP
import Testing

@testable import acp_client

// These tests build `ProbeReport` values directly and read the two forms it
// writes: the plain text of `cli-plan.md` §6, and the JSON of `--json`.
//
// Nothing here spawns a process. The report is a value with no I/O of its own,
// so the rendering can be pinned without an agent, and `ProbeCommandTests` in
// the integration package is left to prove what a real agent puts in it.
//
// The three command states are the reason this file exists. An agent that is
// slow and an agent that has no command both leave the list empty, and a report
// that showed one text for both would say something untrue about the agent.

/// The capabilities the reports in this file carry.
///
/// The tree is two levels deep, so the rendering is read at a nested path and
/// not only at a top-level one.
private let probedCapabilities = AgentCapabilities(
    session: SessionCapabilities(prompt: PromptCapabilities(image: PromptImageCapabilities()))
)

/// The identifier of the authentication method the reports in this file carry.
private let probedAuthMethodID = "stub-oauth"

/// The display name of the authentication method the reports in this file
/// carry.
private let probedAuthMethodName = "Sign in with the stub"

/// The authentication methods the reports in this file carry.
private let probedAuthMethods: [AuthMethod] = [
    .agent(
        AuthMethodAgent(
            methodId: AuthMethodId(rawValue: probedAuthMethodID),
            name: probedAuthMethodName
        )
    )
]

/// The name of the slash command the reports in this file carry.
private let probedCommandName = "create_plan"

/// The description of the slash command the reports in this file carry.
private let probedCommandDescription = "Makes a plan"

/// The slash commands the listed-state reports in this file carry.
private let probedCommands = [
    AvailableCommand(description: probedCommandDescription, name: probedCommandName)
]

/// The three command states this suite renders, in the order the state names
/// are asserted in.
private let commandStates: [ProbeSlashCommands] = [
    .listed(probedCommands),
    .reportedNone,
    .waitEndedFirst,
]

/// Builds one report over the shared fixtures.
///
/// - Parameter slashCommands: The command state the report carries.
/// - Returns: The report.
private func makeReport(slashCommands: ProbeSlashCommands) -> ProbeReport {
    ProbeReport(
        protocolVersion: .v2,
        capabilities: probedCapabilities,
        authMethods: probedAuthMethods,
        slashCommands: slashCommands
    )
}

/// Reads one report's JSON form back as a dictionary.
///
/// - Parameter report: The report to encode.
/// - Returns: The top-level members of the JSON object.
/// - Throws: The encoding failure, or a requirement failure when the text is
///   not a JSON object.
private func jsonMembers(of report: ProbeReport) throws -> [String: Any] {
    let text = try report.jsonText()
    let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try #require(parsed as? [String: Any], "the JSON form was \"\(text)\"")
}

@Suite("acp-client probe report")
struct ProbeReportTests {
    @Test("the plain text names the protocol version, the capabilities and the auth methods")
    func thePlainTextNamesWhatTheAgentReported() {
        let text = makeReport(slashCommands: .listed(probedCommands)).plainText()

        #expect(text.contains("protocol version: \(ProtocolVersion.v2.rawValue)"))
        #expect(text.contains("session.prompt.image"), "the report was \"\(text)\"")
        #expect(text.contains("\(probedAuthMethodID): \(probedAuthMethodName)"))
    }

    @Test("the plain text names no capability the agent did not advertise")
    func thePlainTextOmitsACapabilityThatWasNotAdvertised() {
        let text = makeReport(slashCommands: .listed(probedCommands)).plainText()

        #expect(!text.contains("session.delete"), "the report was \"\(text)\"")
    }

    @Test("the plain text says an empty part is empty rather than printing nothing")
    func thePlainTextNamesAnEmptyPart() {
        let report = ProbeReport(
            protocolVersion: .v2,
            capabilities: AgentCapabilities(),
            authMethods: [],
            slashCommands: .reportedNone
        )

        let text = report.plainText()

        #expect(text.contains("agent capabilities:\n  the agent advertised none"))
        #expect(text.contains("authentication methods:\n  the agent advertised none"))
    }

    @Test("the plain text lists each slash command with its description")
    func thePlainTextListsEachSlashCommand() {
        let text = makeReport(slashCommands: .listed(probedCommands)).plainText()

        #expect(text.contains("\(probedCommandName): \(probedCommandDescription)"))
    }

    @Test("an empty command list and a wait that ended first read differently")
    func theThreeCommandStatesReadDifferently() {
        let listed = makeReport(slashCommands: .listed(probedCommands)).plainText()
        let none = makeReport(slashCommands: .reportedNone).plainText()
        let waitEnded = makeReport(slashCommands: .waitEndedFirst).plainText()

        #expect(none != waitEnded)
        #expect(listed != none)
        #expect(none.contains("the agent reported none"), "the report was \"\(none)\"")
        #expect(
            waitEnded.contains("the agent sent no command list before the wait ended"),
            "the report was \"\(waitEnded)\""
        )
    }

    @Test("the plain form writes no JSON")
    func thePlainFormWritesNoJSON() throws {
        let text = makeReport(slashCommands: .listed(probedCommands)).plainText()

        #expect(JSONSerialization.isValidJSONObject(text) == false)
        #expect(!text.contains("{"), "the report was \"\(text)\"")
    }

    @Test("the JSON form holds the four parts", arguments: commandStates)
    func theJSONFormHoldsTheFourParts(state: ProbeSlashCommands) throws {
        let members = try jsonMembers(of: makeReport(slashCommands: state))

        #expect(members["protocolVersion"] as? Int == Int(ProtocolVersion.v2.rawValue))
        #expect(members["capabilities"] is [String: Any])
        #expect((members["authMethods"] as? [Any])?.count == probedAuthMethods.count)
        #expect(members["slashCommands"] is [String: Any])
    }

    @Test("the JSON form names which of the three command states the report carries")
    func theJSONFormNamesTheCommandState() throws {
        let states = try commandStates.map { state -> String? in
            let commands = try jsonMembers(of: makeReport(slashCommands: state))["slashCommands"]
            return (commands as? [String: Any])?["state"] as? String
        }

        #expect(states == ["listed", "reportedNone", "waitEndedFirst"])
    }

    @Test("the JSON form carries the listed commands, and no other state does")
    func theJSONFormCarriesTheListedCommands() throws {
        let listed = try jsonMembers(of: makeReport(slashCommands: .listed(probedCommands)))
        let none = try jsonMembers(of: makeReport(slashCommands: .reportedNone))

        let commands = try #require(
            (listed["slashCommands"] as? [String: Any])?["commands"] as? [[String: Any]]
        )
        #expect(commands.map { $0["name"] as? String } == [probedCommandName])
        #expect((none["slashCommands"] as? [String: Any])?["commands"] == nil)
    }

    @Test("a report survives its own JSON form", arguments: commandStates)
    func aReportSurvivesItsOwnJSONForm(state: ProbeSlashCommands) throws {
        let report = makeReport(slashCommands: state)

        let decoded = try JSONDecoder().decode(
            ProbeReport.self,
            from: Data(report.jsonText().utf8)
        )

        #expect(decoded == report)
    }

    @Test("an empty command list is the reported-none state")
    func anEmptyCommandListIsTheReportedNoneState() {
        #expect(ProbeSlashCommands.reported([]) == .reportedNone)
        #expect(ProbeSlashCommands.reported(probedCommands) == .listed(probedCommands))
    }
}
