import Foundation
import FoundationModelsExtras
import Testing

@testable import AcpClientCore

// These tests cover the repair `AgentCommandDoctor` asks for when the agent
// command resolves to nothing — the first row of the check table of
// `cli-plan.md` §10.
//
// No test here spawns a process, and none reads the machine's own `PATH`. A
// command that resolves to nothing is never started, so this half of the first
// row is measurable without a process; the row that DOES start the agent lives
// in the nested `IntegrationTests` package, with every other spawning test in
// this repository.

/// The first row of the `doctor` check table, seen from its four failures.
@Suite("acp-client agent command doctor")
struct AgentCommandDoctorTests {
    /// The permission bits of a file its owner may read but not run.
    private static let nonExecutablePermissions = 0o644

    /// A bare command name, chosen so that no `PATH` entry could hold it.
    private static let absentCommandName = "acp-client-doctor-absent-agent"

    /// Builds a doctor over one command, searching a `PATH` holding nothing.
    ///
    /// An empty `PATH` is what makes the bare-name failure hold whatever is
    /// installed on the machine running the test.
    ///
    /// - Parameter command: The agent command to diagnose.
    /// - Returns: A doctor that reads no `PATH` of its own.
    private static func doctor(over command: String) -> AgentCommandDoctor {
        AgentCommandDoctor(command: command, resolver: AgentCommandResolver(path: ""))
    }

    /// Runs the checks over one command and gives back the command row.
    ///
    /// - Parameter command: The agent command to diagnose.
    /// - Returns: The first row of the report.
    /// - Throws: A requirement failure when the report holds no row at all.
    private static func commandRow(for command: String) async throws -> HealthCheck {
        let checks = await doctor(over: command).runHealthChecks()
        return try #require(checks.first)
    }

    /// Names an absolute path that nothing stands at.
    ///
    /// - Returns: A path holding a separator, so the resolver reads it as a
    ///   path rather than as a name to search for.
    private static func absentPath() -> String {
        "/acp-client-doctor-absent-\(UUID().uuidString)/agent"
    }

    /// Writes a file that exists and carries no executable bit.
    ///
    /// - Returns: The absolute path of the file; the caller removes it.
    /// - Throws: A requirement failure when the file could not be written.
    private static func writeNonExecutableFile() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-client-doctor-\(UUID().uuidString)").path
        let written = FileManager.default.createFile(
            atPath: path,
            contents: Data(),
            attributes: [.posixPermissions: nonExecutablePermissions]
        )
        try #require(written, "The test could not write \(path).")
        return path
    }

    @Test("each way the command can fail to resolve names its own repair")
    func eachResolutionFailureNamesItsOwnRepair() async throws {
        let nonExecutable = try Self.writeNonExecutableFile()
        defer { try? FileManager.default.removeItem(atPath: nonExecutable) }

        // The four failures, in the order `AgentCommandResolutionFailure`
        // states them: a name on no PATH, a path standing at nothing, a file
        // carrying no executable bit, and a directory named where a program
        // belongs.
        let rows = [
            try await Self.commandRow(for: Self.absentCommandName),
            try await Self.commandRow(for: Self.absentPath()),
            try await Self.commandRow(for: nonExecutable),
            try await Self.commandRow(for: NSTemporaryDirectory()),
        ]

        #expect(rows.allSatisfy { $0.name == AgentCommandDoctor.commandCheckName })
        #expect(rows.allSatisfy { $0.status == .error })
        let repairs = rows.compactMap(\.fix)
        #expect(repairs.count == rows.count, "a failing row carried no repair")
        // Four distinct repairs, because the four are four different
        // mistakes: a person sent after the wrong one loses the diagnosis.
        #expect(Set(repairs).count == rows.count, "two failures share one repair: \(repairs)")
    }
}
