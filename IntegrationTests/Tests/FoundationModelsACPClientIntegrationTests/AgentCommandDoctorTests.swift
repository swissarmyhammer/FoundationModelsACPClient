import Foundation
import FoundationModelsExtras
import Testing

@testable import AcpClientCore

// These tests drive `AgentCommandDoctor` directly, and never through the
// binary, so each row of the check table of `cli-plan.md` §10 is asserted on
// its own. A row that reports the wrong status, or that carries no fix, sends
// the person reading the report after the wrong repair, and only a per-row
// assertion catches that.
//
// The two rows here are the first two: the command resolves, and the process
// starts and does not end at once. The five rows after them all need a live
// ACP connection, and they belong to the two following tasks.
//
// The suite lives in the nested `IntegrationTests` package because the second
// row spawns a real agent. The root `swift test` never sees this file. The
// unit suite covers what the first row can answer without a process: the
// repair each resolution failure asks for.

/// The number of minutes this file's suite allows itself.
///
/// Each test that reaches the second row spawns a real `/bin/sh` agent and
/// waits out the doctor's own settle interval. That interval is the bound
/// every such test really rests on; this one is the backstop that ends a
/// wedged run rather than holding the package open.
private let doctorSuiteTimeLimitMinutes = 5

/// The rows a report carries, in the order the doctor reports them.
///
/// The order is the content: the command row stands first because the process
/// row rests on it. Comparing the whole list also states that the report holds
/// these rows and no others.
private let checkNamesInOrder = [
    AgentCommandDoctor.commandCheckName,
    AgentCommandDoctor.processCheckName,
]

/// Names a bare command that no `PATH` directory holds.
///
/// The first row is what this feeds, so the name must fail to resolve on every
/// machine, CI included. A fresh UUID inside the name is what makes that true
/// whatever is installed.
///
/// - Returns: A command name holding no path separator.
private func unresolvableAgentCommand() -> String {
    "acp-client-doctor-no-such-agent-\(UUID().uuidString)"
}

/// The first two rows of the `doctor` check table, against real agents.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes, so the tests must not share
/// a moment on a loaded machine.
@Suite(
    "AgentCommandDoctor: the command resolves, and the process starts and stays",
    .serialized,
    .timeLimit(.minutes(doctorSuiteTimeLimitMinutes))
)
struct AgentCommandDoctorTests {
    /// The text that stands before the unique part of a pid file's name.
    private static let pidFileNamePrefix = "acp-client-doctor-agent-pid-"

    /// Builds the doctor one test drives against a stub-agent script.
    ///
    /// The scripts carry no execute bit, so the agent command is the shell and
    /// the script is its argument, which is also the shape `cli-plan.md` §6
    /// gives an agent that takes arguments of its own.
    ///
    /// - Parameter script: The absolute path of the stub-agent script.
    /// - Returns: A doctor over that agent.
    private static func doctor(over script: String) -> AgentCommandDoctor {
        AgentCommandDoctor(command: stubAgentShellCommand, arguments: [script])
    }

    @Test("the doctor reports under the command it was given, in one category")
    func theDoctorReportsUnderTheCommandItWasGiven() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        // The binding is the assertion for the protocol itself: an existential
        // of `Doctorable` accepts this value only while the conformance holds,
        // and the call below compiles without `try` only while
        // `runHealthChecks()` stays non-throwing.
        let doctorable: any Doctorable = Self.doctor(over: script)
        let checks = await doctorable.runHealthChecks()

        #expect(doctorable.doctorName == stubAgentShellCommand)
        #expect(!doctorable.doctorCategory.isEmpty)
        #expect(checks.allSatisfy { $0.category == doctorable.doctorCategory })
    }

    @Test("a passing row carries no fix, and every warning and error carries one")
    func everyFindingObeysTheFixRule() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let started = await Self.doctor(over: script).runHealthChecks()
        let unresolved = await AgentCommandDoctor(
            command: unresolvableAgentCommand()
        ).runHealthChecks()

        for check in started + unresolved {
            switch check.status {
            case .ok:
                #expect(check.fix == nil, "\(check.name) passed and still carries a fix")
            case .warning, .error:
                #expect(
                    check.fix?.isEmpty == false,
                    "\(check.name) is a \(check.status) carrying no fix"
                )
            }
        }
    }

    @Test("a command that is on no PATH fails the first row and skips the second")
    func aCommandThatIsOnNoPathFailsTheFirstRow() async {
        let command = unresolvableAgentCommand()

        let checks = await AgentCommandDoctor(command: command).runHealthChecks()

        // The second row is reported and not dropped, so a report always has
        // the same shape. `HealthStatus` states no "skipped", so the row that
        // did not run is a warning naming the row to repair first.
        #expect(checks.map(\.name) == checkNamesInOrder)
        #expect(checks.map(\.status) == [.error, .warning])
        #expect(checks.first?.message.contains(command) == true)
        #expect(checks.last?.message.contains(AgentCommandDoctor.commandCheckName) == true)
    }

    @Test("an agent that ends the moment it starts fails the second row")
    func anAgentThatEndsAtOnceFailsTheSecondRow() async throws {
        let script = try makeExitingAtOnceAgent()
        defer { removeAgentScript(script) }

        let checks = await Self.doctor(over: script).runHealthChecks()

        #expect(checks.map(\.name) == checkNamesInOrder)
        #expect(checks.map(\.status) == [.ok, .error])
        #expect(checks.last?.fix?.isEmpty == false)
    }

    @Test("an agent that starts and stays passes both rows")
    func anAgentThatStartsAndStaysPassesBothRows() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let checks = await Self.doctor(over: script).runHealthChecks()

        #expect(checks.map(\.name) == checkNamesInOrder)
        #expect(checks.map(\.status) == [.ok, .ok])
    }

    @Test("no agent process outlives the checks")
    func noAgentProcessOutlivesTheChecks() async throws {
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try makeWellBehavedAgent(pidFile: pidFile.path)
        defer { removeAgentScript(script) }

        let checks = await Self.doctor(over: script).runHealthChecks()

        // The agent stayed while the checks ran, so the pid the script wrote
        // is the pid the doctor had to reap. `cli-plan.md` §11 lets no agent
        // outlive the command that started it.
        #expect(checks.last?.status == .ok)
        let pid = try recordedAgentPid(in: pidFile)
        #expect(!processExists(pid), "the agent with pid \(pid) outlived the checks")
    }
}
