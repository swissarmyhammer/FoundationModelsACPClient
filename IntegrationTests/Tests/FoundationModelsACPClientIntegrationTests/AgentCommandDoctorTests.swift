import Foundation
import FoundationModelsACPClient
import FoundationModelsExtras
import Testing

@testable import AcpClientCore

// These tests drive `AgentCommandDoctor` directly, and never through the
// binary, so each row of the check table of `cli-plan.md` §10 is asserted on
// its own. A row that reports the wrong status, or that carries no fix, sends
// the person reading the report after the wrong repair, and only a per-row
// assertion catches that.
//
// The five rows here are the first five: the command resolves, the process
// starts and does not end at once, standard output carries ndJSON and nothing
// else, `initialize` answers inside the time limit, and the protocol version is
// the one that was sent. The two rows after them belong to the following task.
//
// The suite lives in the nested `IntegrationTests` package because every row
// after the first spawns a real agent. The root `swift test` never sees this
// file. The unit suite covers what the first row can answer without a process:
// the repair each resolution failure asks for.
//
// Two rows are measured by the CLOCK as well as by the report, because a check
// that hangs and a check that fails are the same report with a different wait.
// Each such test bounds the whole `runHealthChecks()` call and fails the moment
// the bound passes, rather than leaving the suite's own backstop to end a
// wedged run minutes later.

/// The number of minutes this file's suite allows itself.
///
/// Each test that reaches the second row spawns a real `/bin/sh` agent and
/// waits out the doctor's own settle interval. That interval is the bound
/// every such test really rests on; this one is the backstop that ends a
/// wedged run rather than holding the package open.
private let doctorSuiteTimeLimitMinutes = 5

/// The rows a report carries, in the order the doctor reports them.
///
/// The order is the content: each row rests on the ones before it, so the
/// standard-output row stands where `cli-plan.md` §10 puts it, ahead of the two
/// rows that read the `initialize` answer. Comparing the whole list also states
/// that the report holds these rows and no others.
private let checkNamesInOrder = [
    AgentCommandDoctor.commandCheckName,
    AgentCommandDoctor.processCheckName,
    AgentCommandDoctor.standardOutputCheckName,
    AgentCommandDoctor.initializeCheckName,
    AgentCommandDoctor.protocolVersionCheckName,
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

/// The first five rows of the `doctor` check table, against real agents.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes, so the tests must not share
/// a moment on a loaded machine.
@Suite(
    "AgentCommandDoctor: the command, the process, stdout, initialize and the version",
    .serialized,
    .timeLimit(.minutes(doctorSuiteTimeLimitMinutes))
)
struct AgentCommandDoctorTests {
    /// The text that stands before the unique part of a pid file's name.
    private static let pidFileNamePrefix = "acp-client-doctor-agent-pid-"

    /// The number of seconds ``shortTimeLimit`` covers.
    private static let shortTimeLimitSeconds = 2

    /// The doctor time limit the tests that must REACH the limit are given.
    ///
    /// The default of ten seconds is the right patience for a person running a
    /// diagnosis and the wrong wait for a suite, so a test that drives a silent
    /// agent states a shorter one. It is still far longer than the handshake
    /// every other test here completes.
    private static let shortTimeLimit: Duration = .seconds(shortTimeLimitSeconds)

    /// The number of seconds ``runReturnBound`` covers.
    private static let runReturnBoundSeconds = 20

    /// The longest a whole `runHealthChecks()` call may take in this suite.
    ///
    /// It stands well over the work every test here does — a spawn, the
    /// doctor's own half-second settle, and at most ``shortTimeLimit`` of
    /// waiting — so a loaded machine does not fail a sound run. It is also far
    /// under the suite's backstop, so a check that never returns fails as the
    /// hang it is rather than as a wedged suite.
    private static let runReturnBound: Duration = .seconds(runReturnBoundSeconds)

    /// Builds the doctor one test drives against a stub-agent script.
    ///
    /// The scripts carry no execute bit, so the agent command is the shell and
    /// the script is its argument, which is also the shape `cli-plan.md` §6
    /// gives an agent that takes arguments of its own.
    ///
    /// - Parameters:
    ///   - script: The absolute path of the stub-agent script.
    ///   - timeLimit: The longest one row may take.
    /// - Returns: A doctor over that agent.
    private static func doctor(
        over script: String,
        timeLimit: Duration = AgentCommandDoctor.defaultTimeLimit
    ) -> AgentCommandDoctor {
        AgentCommandDoctor(
            command: stubAgentShellCommand,
            arguments: [script],
            timeLimit: timeLimit
        )
    }

    /// Runs every check over one stub-agent script, and times the run.
    ///
    /// The elapsed time is what makes a hang measurable: `cli-plan.md` §10 asks
    /// the fourth row to report a timeout rather than to become one, and only a
    /// clock reading tells the two apart.
    ///
    /// - Parameters:
    ///   - script: The absolute path of the stub-agent script.
    ///   - timeLimit: The longest one row may take.
    /// - Returns: The report, and how long the whole call took.
    private static func timedChecks(
        over script: String,
        timeLimit: Duration = AgentCommandDoctor.defaultTimeLimit
    ) async -> (checks: [HealthCheck], elapsed: Duration) {
        let started = ContinuousClock.now
        let checks = await doctor(over: script, timeLimit: timeLimit).runHealthChecks()
        return (checks, ContinuousClock.now - started)
    }

    /// Picks one row out of a report by name.
    ///
    /// - Parameters:
    ///   - name: The row to read.
    ///   - checks: The report.
    /// - Returns: That row.
    /// - Throws: A requirement failure when the report holds no such row.
    private static func row(named name: String, in checks: [HealthCheck]) throws -> HealthCheck {
        try #require(checks.first { $0.name == name }, "the report holds no row named \(name)")
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
        let silent = try makeSilentAgent()
        defer { removeAgentScript(silent) }

        let started = await Self.doctor(over: script).runHealthChecks()
        let timedOut = await Self.doctor(over: silent, timeLimit: Self.shortTimeLimit)
            .runHealthChecks()
        let unresolved = await AgentCommandDoctor(
            command: unresolvableAgentCommand()
        ).runHealthChecks()

        for check in started + timedOut + unresolved {
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

    @Test("a command that is on no PATH fails the first row and skips every later row")
    func aCommandThatIsOnNoPathFailsTheFirstRow() async throws {
        let command = unresolvableAgentCommand()

        let checks = await AgentCommandDoctor(command: command).runHealthChecks()

        // Every later row is reported and not dropped, so a report always has
        // the same shape. `HealthStatus` states no "skipped", so a row that
        // did not run is a warning naming the row to repair first.
        #expect(checks.map(\.name) == checkNamesInOrder)
        #expect(checks.map(\.status) == [.error, .warning, .warning, .warning, .warning])
        #expect(checks.first?.message.contains(command) == true)
        for skipped in checks.dropFirst() {
            #expect(skipped.message.contains(AgentCommandDoctor.commandCheckName))
        }
    }

    @Test("an agent that ends the moment it starts fails the second row and skips the rest")
    func anAgentThatEndsAtOnceFailsTheSecondRow() async throws {
        let script = try makeExitingAtOnceAgent()
        defer { removeAgentScript(script) }

        let checks = await Self.doctor(over: script).runHealthChecks()

        #expect(checks.map(\.name) == checkNamesInOrder)
        #expect(checks.map(\.status) == [.ok, .error, .warning, .warning, .warning])
        for skipped in checks.dropFirst(2) {
            #expect(skipped.message.contains(AgentCommandDoctor.processCheckName))
        }
    }

    @Test("an agent that answers the handshake passes every row, and no read blocks")
    func aWellBehavedAgentPassesEveryRow() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (checks, elapsed) = await Self.timedChecks(over: script)

        #expect(checks.map(\.name) == checkNamesInOrder)
        #expect(checks.map(\.status) == [.ok, .ok, .ok, .ok, .ok])
        // A conformant agent writes to stdout only in ANSWER to a request, so a
        // standard-output row that read before it asked would wait here for
        // ever. The bound is what states that it does not.
        #expect(
            elapsed < Self.runReturnBound,
            "the checks took \(elapsed) over a conformant agent"
        )
    }

    @Test("a banner on stdout fails the standard-output row, quoting the line")
    func aBannerOnStdoutFailsTheStandardOutputRow() async throws {
        let script = try makeBannerOnStdoutAgent()
        defer { removeAgentScript(script) }

        let (checks, elapsed) = await Self.timedChecks(over: script)

        let standardOutput = try Self.row(
            named: AgentCommandDoctor.standardOutputCheckName,
            in: checks
        )
        #expect(standardOutput.status == .error)
        #expect(
            standardOutput.message.contains(stubAgentBannerLine),
            "the row did not quote the offending line: \(standardOutput.message)"
        )
        // The wire package logs a line it cannot decode and reads the next one,
        // so the handshake still completes. That is what makes this row worth
        // the command on its own: it is the only row that catches the defect.
        #expect(checks.map(\.status) == [.ok, .ok, .error, .ok, .ok])
        #expect(elapsed < Self.runReturnBound, "the checks took \(elapsed)")
    }

    @Test("an agent that never answers fails the initialize row at the limit")
    func aSilentAgentFailsTheInitializeRow() async throws {
        let script = try makeSilentAgent()
        defer { removeAgentScript(script) }

        let (checks, elapsed) = await Self.timedChecks(
            over: script,
            timeLimit: Self.shortTimeLimit
        )

        let initialize = try Self.row(named: AgentCommandDoctor.initializeCheckName, in: checks)
        #expect(initialize.status == .error)
        #expect(
            initialize.message.contains("\(Self.shortTimeLimit)"),
            "the row did not name the limit it reached: \(initialize.message)"
        )
        // The agent wrote nothing, so the standard-output row had nothing to
        // judge and the protocol-version row had no answer to read. Both are
        // reported as rows that did not run, beside the error that caused it.
        #expect(checks.map(\.status) == [.ok, .ok, .warning, .error, .warning])
        #expect(
            elapsed < Self.runReturnBound,
            "the checks took \(elapsed) against a silent agent"
        )
    }

    @Test("an agent that answers with another protocol version fails the version row")
    func aWrongProtocolVersionFailsTheVersionRow() async throws {
        let script = try makeWrongProtocolVersionAgent()
        defer { removeAgentScript(script) }

        let checks = await Self.doctor(over: script).runHealthChecks()

        let version = try Self.row(named: AgentCommandDoctor.protocolVersionCheckName, in: checks)
        #expect(version.status == .error)
        // Both versions, because "a v1 agent, or a newer draft" is only
        // actionable when the report says which version each side spoke.
        #expect(
            version.message.contains("\(ACPClient.supportedProtocolVersion.rawValue)"),
            "the row did not name the version this client sent: \(version.message)"
        )
        #expect(
            version.message.contains("\(stubAgentUnsupportedProtocolVersion.rawValue)"),
            "the row did not name the version the agent answered: \(version.message)"
        )
        // The agent DID answer, and it answered in time, so the fourth row
        // passes and the failure stands on the fifth row alone.
        #expect(checks.map(\.status) == [.ok, .ok, .ok, .ok, .error])
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
        #expect(checks.allSatisfy { $0.status == .ok })
        let pid = try recordedAgentPid(in: pidFile)
        #expect(!processExists(pid), "the agent with pid \(pid) outlived the checks")
    }

    @Test("no agent process outlives the checks when the initialize row times out")
    func noAgentProcessOutlivesTheChecksAfterATimeout() async throws {
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try makeSilentAgent(pidFile: pidFile.path)
        defer { removeAgentScript(script) }

        let checks = await Self.doctor(over: script, timeLimit: Self.shortTimeLimit)
            .runHealthChecks()

        // The failing path reaps too. A silent agent stays alive until its
        // stdin closes, so nothing but the doctor's own teardown ends it.
        let initialize = try Self.row(named: AgentCommandDoctor.initializeCheckName, in: checks)
        #expect(initialize.status == .error)
        let pid = try recordedAgentPid(in: pidFile)
        #expect(!processExists(pid), "the agent with pid \(pid) outlived the checks")
    }

    @Test("no agent process outlives the checks when the version row fails")
    func noAgentProcessOutlivesTheChecksAfterAVersionMismatch() async throws {
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try makeWrongProtocolVersionAgent(pidFile: pidFile.path)
        defer { removeAgentScript(script) }

        let checks = await Self.doctor(over: script).runHealthChecks()

        let version = try Self.row(named: AgentCommandDoctor.protocolVersionCheckName, in: checks)
        #expect(version.status == .error)
        let pid = try recordedAgentPid(in: pidFile)
        #expect(!processExists(pid), "the agent with pid \(pid) outlived the checks")
    }
}
