import Foundation
import Testing

// The §11 sweep of `cli-plan.md`: "**No agent process outlives the run.** This
// holds after success, after a failure, after a timeout, and after an
// interrupt. A leaked agent holds gigabytes of model weights, so a test asserts
// each path."
//
// Every row here drives the real `acp-client` binary against a real foreign
// agent, reads the agent's own pid out of a file the agent wrote, and asks
// `kill(pid, 0)` whether anything is still there. The reading is taken from
// OUTSIDE the finished run, which is the only place the no-leak claim can be
// measured at all.
//
// This file holds the paths no other suite proves, and it repeats none of
// them. The rest of the sweep lives where the behaviour it belongs to is
// asserted:
//
// | The path | Where the pid is read |
// |---|---|
// | `run`, each of the four turn endings | `RunCommandExitTests` |
// | `run`, the limit of `--timeout`, exit 124 | `TimeoutTests` |
// | `run`, one `Ctrl-C` and two `Ctrl-C`, exit 4 | `InterruptTests` |
// | `probe`, the agent answers, and the agent refuses `initialize` | `ProbeCommandTests` |
// | the `doctor` CHECKS, five rows | `AgentCommandDoctorTests` |
// | `AgentProcess`, a grandchild of the agent | `AgentProcessTests` |
//
// What is left, and what stands below: the agent that goes away in the middle
// of a turn, the agent that refuses `session/new`, a grandchild reached through
// the BINARY rather than through the library, an agent with no `session/close`,
// the probe whose bounded wait for a command list ends first, the agent that
// ends the moment it starts, the `doctor` SUBCOMMAND, and a spawn that fails
// before there is an agent at all.
//
// **This file claims no reap, and it cannot.** Two instruments were weighed,
// and neither states the reap from out here. `waitpid` answers `ECHILD` for
// every pid that is not a child of the caller, and the stub agent is a child of
// `acp-client` and a GRANDCHILD of this process, so `waitpid` from here answers
// the same whether the agent is alive or dead. ``processExists(_:)`` reads
// `kill(pid, 0)`, which still reaches a ZOMBIE, so it is sound for the one
// question this file asks — is anything STILL ALIVE — and it cannot fail for
// the reap either: every reading here is taken after `acp-client` has exited,
// and a parent that exits hands its unreaped children to `launchd`, which reaps
// them at once. Measured on this machine: while the parent still runs, an
// unreaped child is REACHABLE; after the parent exited, the same pid answers
// `ESRCH`. So the pid is gone whether or not `acp-client` reaped it.
//
// The reap is proven where the reader IS the parent and stays alive to take the
// reading: `AgentProcessTests.killingAgentSurfacesDisconnectedState` kills the
// agent that `AgentProcess` spawned from THIS process and then asserts the pid
// is gone, which a zombie fails. Measured with the `waitpid` taken out of
// `AgentProcessState.terminateCurrent()`: that row and its three neighbours all
// go red.
//
// Nothing here can import the binary's own types: SwiftPM builds an executable
// product for this test bundle to spawn, and it publishes no module to an other
// package. The exit codes stand in ``SectionNineExitCode``.

/// The number of minutes this file's suite allows itself.
///
/// Every row spawns two real processes, and the repeat row drives every row
/// twice, so a loaded machine must not fail a suite that is only slow. The
/// bound each row really rests on is ``noLeakRunBound``; this one is the
/// backstop that ends a wedged run rather than holding the package open.
private let noLeakSuiteTimeLimitMinutes = 5

/// The number of seconds ``noLeakRunBound`` covers.
private let noLeakRunBoundSeconds = 30

/// The longest one run of this file may take.
///
/// It stands well over the slowest row — a `doctor` run, which pays the
/// doctor's own settle interval and its teardown watch — and far under the
/// suite's own backstop, so a run that hangs fails as the hang it is.
///
/// That holds for the failure this file exists to detect, and not by accident.
/// A LEAKED agent inherits the harness's stderr write end, so a blocking read of
/// that pipe would outlast this bound and wedge the suite. `runAcpClient` reads
/// both pipes as the bytes arrive and gives up at a grace of its own instead, so
/// a leak comes back here as a row that names its pid.
private let noLeakRunBound: Duration = .seconds(noLeakRunBoundSeconds)

/// The prompt every `run` row of this file sends.
///
/// No row here asserts on the prompt — `RunCommandExitTests` owns the
/// prompt-source table — so one text serves them all.
private let noLeakPrompt = "write a haiku"

/// How many pids a stub agent that records only its own writes.
private let oneRecordedPid = 1

/// One exit path of one subcommand, and the stub agent that reaches it.
///
/// Each case is a path `cli-plan.md` §11 covers and no earlier card proved with
/// a pid. The four members below are the whole of what a row needs: the agent
/// to drive, the command line to drive it with, the exit code §9 owes the path,
/// and how many pids the agent records.
enum NoLeakScenario: CaseIterable, Sendable, CustomStringConvertible {
    /// `run` against an agent that streams a chunk and then EXITS, with no
    /// `idle` update at all.
    ///
    /// The agent dies while the binary is still running, so this is the path on
    /// which `AgentProcess` reaps from the EOF branch of its reader. The reap
    /// itself is NOT what this row states — the file header says why, and names
    /// the seam that does state it. What stands here is the §9 exit code, and
    /// that no process outlived the run.
    case runReachesAnAgentThatGoesAwayMidTurn

    /// `run` against an agent that answers `initialize` and refuses
    /// `session/new`.
    case runReachesAnAgentThatRefusesTheSession

    /// `run` against an agent that spawns a child of its own and leaves it
    /// running.
    ///
    /// It is the grandchild row, reached through the BINARY.
    /// `AgentProcessTests` proves the group kill at the library seam; this row
    /// proves the binary still runs it.
    case runReachesAnAgentThatLeftAChild

    /// `probe` against an agent that answers `initialize` and refuses
    /// `session/new`.
    case probeReachesAnAgentThatRefusesTheSession

    /// `probe` against an agent that sends no `available_commands_update`, so
    /// the probe's own bounded wait ends first.
    case probeReachesAnAgentThatReportsNoCommandList

    /// `probe` against an agent that reports `methodNotFound` for
    /// `session/close`.
    case probeReachesAnAgentWithNoSessionClose

    /// `probe` against an agent that ends the moment it starts.
    case probeReachesAnAgentThatEndsAtOnce

    /// `doctor` against an agent that passes every row of the check table.
    case doctorReachesAnAgentThatPassesEveryRow

    /// `doctor` against an agent that writes a banner to stdout, which the
    /// third row of the check table reports as an error.
    case doctorReachesAnAgentThatFailsARow

    /// The exit path this row walks, named as a person would name it.
    ///
    /// Every failure message of this file quotes it, because a sweep that says
    /// only "a process outlived the run" leaves the reader to find out which
    /// run.
    var description: String {
        switch self {
        case .runReachesAnAgentThatGoesAwayMidTurn:
            "run, against an agent that goes away in the middle of the turn"
        case .runReachesAnAgentThatRefusesTheSession:
            "run, against an agent that refuses session/new"
        case .runReachesAnAgentThatLeftAChild:
            "run, against an agent that leaves a child behind"
        case .probeReachesAnAgentThatRefusesTheSession:
            "probe, against an agent that refuses session/new"
        case .probeReachesAnAgentThatReportsNoCommandList:
            "probe, against an agent that reports no command list"
        case .probeReachesAnAgentWithNoSessionClose:
            "probe, against an agent that does not implement session/close"
        case .probeReachesAnAgentThatEndsAtOnce:
            "probe, against an agent that ends the moment it starts"
        case .doctorReachesAnAgentThatPassesEveryRow:
            "doctor, against an agent that passes every row"
        case .doctorReachesAnAgentThatFailsARow:
            "doctor, against an agent that writes a banner to stdout"
        }
    }

    /// The exit code `cli-plan.md` §9 owes this path.
    ///
    /// It is asserted beside the pid on every row. A run that ended on the
    /// wrong path proves nothing about the path this row means to sweep, so the
    /// two claims stand together.
    var exitCode: Int32 {
        switch self {
        case .runReachesAnAgentThatGoesAwayMidTurn,
            .runReachesAnAgentThatRefusesTheSession,
            .probeReachesAnAgentThatRefusesTheSession,
            .probeReachesAnAgentThatEndsAtOnce,
            .doctorReachesAnAgentThatFailsARow:
            SectionNineExitCode.failure
        case .runReachesAnAgentThatLeftAChild,
            .probeReachesAnAgentThatReportsNoCommandList,
            .probeReachesAnAgentWithNoSessionClose,
            .doctorReachesAnAgentThatPassesEveryRow:
            SectionNineExitCode.success
        }
    }

    /// How many pids this row's agent records.
    ///
    /// Reading the count is what makes the grandchild row a real claim: an
    /// agent that never spawned its child would record one pid, and the row
    /// would then pass while measuring nothing.
    var recordedPidCount: Int {
        self == .runReachesAnAgentThatLeftAChild
            ? stubAgentChildLeavingPidCount
            : oneRecordedPid
    }

    /// Writes the stub agent this row drives.
    ///
    /// - Parameter pidFile: Where the agent records its own pid.
    /// - Returns: The absolute path of the script; the caller removes it.
    /// - Throws: A JSON-encoding failure, or the write failure of the script.
    func makeAgent(pidFile: String) throws -> String {
        switch self {
        case .runReachesAnAgentThatGoesAwayMidTurn:
            try makeExitingMidTurnAgent(pidFile: pidFile)
        case .runReachesAnAgentThatRefusesTheSession,
            .probeReachesAnAgentThatRefusesTheSession:
            try makeNewSessionRefusingAgent(pidFile: pidFile)
        case .runReachesAnAgentThatLeftAChild:
            try makeChildLeavingAgent(pidFile: pidFile)
        case .probeReachesAnAgentThatReportsNoCommandList:
            try makeProbeAgent(commands: .noUpdate, pidFile: pidFile)
        case .probeReachesAnAgentWithNoSessionClose:
            try makeSessionCloseRefusingAgent(pidFile: pidFile)
        case .probeReachesAnAgentThatEndsAtOnce:
            try makeExitingAtOnceAgent(pidFile: pidFile)
        case .doctorReachesAnAgentThatPassesEveryRow:
            try makeWellBehavedAgent(pidFile: pidFile)
        case .doctorReachesAnAgentThatFailsARow:
            try makeBannerOnStdoutAgent(pidFile: pidFile)
        }
    }

    /// The command line this row runs.
    ///
    /// - Parameter script: The absolute path of the stub-agent script.
    /// - Returns: The arguments for ``runAcpClient(_:standardInput:standardOutput:environment:signals:within:)``.
    func arguments(script: String) -> [String] {
        switch self {
        case .runReachesAnAgentThatGoesAwayMidTurn,
            .runReachesAnAgentThatRefusesTheSession,
            .runReachesAnAgentThatLeftAChild:
            runArguments(prompt: noLeakPrompt, script: script)
        case .probeReachesAnAgentThatRefusesTheSession,
            .probeReachesAnAgentThatReportsNoCommandList,
            .probeReachesAnAgentWithNoSessionClose,
            .probeReachesAnAgentThatEndsAtOnce:
            agentCommandArguments(probeSubcommandName, script: script)
        case .doctorReachesAnAgentThatPassesEveryRow,
            .doctorReachesAnAgentThatFailsARow:
            agentCommandArguments(doctorSubcommandName, script: script)
        }
    }
}

/// `cli-plan.md` §11, over the exit paths no other suite reads a pid on.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes.
@Suite(
    "acp-client leaves no agent behind",
    .serialized,
    .timeLimit(.minutes(noLeakSuiteTimeLimitMinutes))
)
struct NoLeakedAgentTests {
    /// The text that stands before the unique part of a pid file's name.
    private static let pidFileNamePrefix = "acp-client-no-leak-agent-pid-"

    /// Drives one exit path and asserts that it left no process behind.
    ///
    /// The exit code is asserted first, because a run that ended on some other
    /// path never reached the one this row sweeps. Each message names the path,
    /// and the pid message names the pid, so a failure says which process
    /// outlived which run.
    ///
    /// - Parameter scenario: The exit path to walk.
    /// - Throws: A script-writing failure, a run failure, or the bound of
    ///   ``noLeakRunBound``.
    private static func expectNothingOutlives(_ scenario: NoLeakScenario) async throws {
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try scenario.makeAgent(pidFile: pidFile.path)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            scenario.arguments(script: script),
            within: noLeakRunBound
        )

        #expect(
            result.exitCode == scenario.exitCode,
            "\(scenario) exited \(result.exitCode) rather than \(scenario.exitCode)"
        )
        let pids = try recordedAgentPids(in: pidFile)
        #expect(
            pids.count == scenario.recordedPidCount,
            "\(scenario) recorded \(pids.count) pids rather than \(scenario.recordedPidCount)"
        )
        for pid in pids {
            #expect(
                !processExists(pid),
                "the process with pid \(pid) outlived \(scenario)"
            )
        }
    }

    @Test("no agent process outlives the run", arguments: NoLeakScenario.allCases)
    func noAgentProcessOutlivesTheRun(scenario: NoLeakScenario) async throws {
        try await Self.expectNothingOutlives(scenario)
    }

    /// The whole sweep, twice in a row.
    ///
    /// A reap that leaked a descriptor rather than a process passes the first
    /// pass and fails the second: the binary of the second run inherits nothing
    /// from the first, but the MACHINE carries whatever the first left. So the
    /// second pass asserts the same contract the first one did, row for row,
    /// and a pass that disagreed with the contract is the finding.
    @Test("the whole sweep runs twice in a row, and the second pass is unaffected")
    func theWholeSweepRunsTwiceInARow() async throws {
        for scenario in NoLeakScenario.allCases {
            try await Self.expectNothingOutlives(scenario)
        }
        for scenario in NoLeakScenario.allCases {
            try await Self.expectNothingOutlives(scenario)
        }
    }

    /// A spawn that fails before there is an agent.
    ///
    /// It is the one row of §11 with no pid to read, and it is a row all the
    /// same: `AgentProcess` opens four descriptors before it calls
    /// `posix_spawn`, so a failure there has four things to give back and no
    /// child to reap. A run that leaked those descriptors leaves the NEXT run
    /// to fail, which is why the two runs stand in one test — the second one is
    /// the assertion the first one has no pid for.
    @Test("a spawn that fails leaves nothing behind, and the next run still works")
    func aFailedSpawnLeavesNothingBehind() async throws {
        let unexecutable = try makeUnexecutableAgentBinary()
        defer { removeAgentScript(unexecutable) }
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try makeWellBehavedAgent(pidFile: pidFile.path)
        defer { removeAgentScript(script) }

        let failed = try await runAcpClient(
            [runSubcommandName, noLeakPrompt, agentCommandSeparator, unexecutable],
            within: noLeakRunBound
        )
        let next = try await runAcpClient(
            runArguments(prompt: noLeakPrompt, script: script),
            within: noLeakRunBound
        )

        #expect(failed.exitCode == SectionNineExitCode.failure)
        #expect(failed.standardOutput.isEmpty)
        let reported = String(decoding: failed.standardError, as: UTF8.self)
        #expect(
            reported.contains(URL(fileURLWithPath: unexecutable).lastPathComponent),
            "the failed spawn did not name the command it could not run: \"\(reported)\""
        )
        #expect(next.exitCode == SectionNineExitCode.success)
        let pid = try recordedAgentPid(in: pidFile)
        #expect(
            !processExists(pid),
            "the agent with pid \(pid) outlived the run that followed a failed spawn"
        )
    }
}
