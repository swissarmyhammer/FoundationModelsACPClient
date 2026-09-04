import ArgumentParser
import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import FoundationModelsExtras
import Testing

@testable import AcpClientCore

/// Finds the numeric exit-code literals a Swift file holds.
///
/// The scan reads code alone. Comments and string literals go first, because
/// `cli-plan.md` §9 is quoted all over this target — a doc comment saying "and
/// exits 2" is documentation, not a second copy of the table.
///
/// What remains is read one line at a time: a line that mentions an exit and
/// also spells a decimal number is a copy of the table. The two halves are both
/// needed. "Exit" alone matches every mention of ``AcpClientExitCode``, and a
/// number alone matches an array index.
///
/// The number is matched at word boundaries, so the `32` inside `Int32` is not
/// a literal. The scan reads decimal literals only: a hexadecimal or a binary
/// spelling of an exit code would pass it.
private enum ExitCodeLiteralScan {
    /// The one file of the command-line client that is allowed to spell the §9
    /// numbers.
    static let tableFileName = "ExitCode.swift"

    /// Returns each place in one Swift file where a line of code names an exit
    /// and spells a decimal number.
    ///
    /// - Parameter file: The Swift file to read.
    /// - Returns: One `file:line` string for each such line, empty when the
    ///   file holds none.
    /// - Throws: Whatever reading the file throws.
    static func literals(in file: URL) throws -> [String] {
        // Both patterns are local because `Regex` is not `Sendable`, so
        // neither can be a static constant.
        let exitMention = /(?i)exit/
        let decimalLiteral = /\b[0-9]+\b/
        let source = try String(contentsOf: file, encoding: .utf8)
        return codeOnly(in: source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.element.contains(exitMention) && $0.element.contains(decimalLiteral) }
            .map { "\(file.lastPathComponent):\($0.offset + 1)" }
    }

    /// Returns the given Swift source with every comment and string literal
    /// taken out.
    ///
    /// Each removed run leaves its line breaks behind, so a line number of the
    /// result is the line number of the source.
    ///
    /// - Parameter source: The text of a Swift file.
    /// - Returns: The same text, holding code alone.
    private static func codeOnly(in source: String) -> String {
        // The alternation is ordered: a line comment, a block comment, a
        // multi-line string, then a single-line string. The two string forms
        // come last so that a "//" inside a string is read as part of the
        // string, and the multi-line form comes before the single-line form so
        // that its opening delimiter is not read as an empty string.
        let commentOrStringLiteral =
            /\/\/[^\n]*|\/\*(?s:.*?)\*\/|"""(?s:.*?)"""|"(?:[^"\\\n]|\\.)*"/
        return source.replacing(commentOrStringLiteral) { match in
            String(repeating: "\n", count: match.output.filter(\.isNewline).count)
        }
    }
}

/// Pins the exit code table of `cli-plan.md` §9, and every outcome that maps
/// into it.
///
/// The table is one value with no I/O, so these tests state each row as data
/// and compare it with the row the code carries. `cli-plan.md` §17 gives
/// `acp-agent` the same table, so a renumbering here is a divergence between
/// two binaries, and each test below is written to catch it by name.
@Suite("acp-client exit codes")
struct ExitCodeTests {
    /// The exit code table of `cli-plan.md` §9, written out.
    ///
    /// This is the expected side of the comparison, so it is spelled here and
    /// not read from the code under test. A renumbering fails one row of
    /// ``everyExitCodeCarriesItsSectionNineNumber()``.
    private static let sectionNineTable: [AcpClientExitCode: Int32] = [
        .success: 0,
        .failure: 1,
        .usage: 2,
        .refusal: 3,
        .cancelled: 4,
        .doctorWarning: 5,
        .timeout: 124,
    ]

    /// The number of cases `StopReason` carries on the wire this build reads.
    ///
    /// `StopReason` is not `CaseIterable` and `unknown` holds an associated
    /// value, so no test can iterate it. ``stopReasonRows`` is the explicit
    /// list instead, and this count is what keeps a row from being dropped
    /// from that list without a failure.
    private static let stopReasonCaseCount = 6

    /// A stop reason this build does not know, as a newer agent would send it.
    private static let unknownStopReason = "something-new"

    /// Each `StopReason`, beside the exit code `cli-plan.md` §9 owes it.
    private static let stopReasonRows: [(reason: StopReason, code: AcpClientExitCode)] = [
        (.endTurn, .success),
        (.maxTokens, .success),
        (.maxTurnRequests, .success),
        (.refusal, .refusal),
        (.cancelled, .cancelled),
        (.unknown(unknownStopReason), .success),
    ]

    /// Each `HealthStatus`, beside the exit code `cli-plan.md` §9 owes it.
    private static let doctorStatusRows: [(status: HealthStatus, code: AcpClientExitCode)] = [
        (.ok, .success),
        (.warning, .doctorWarning),
        (.error, .failure),
    ]

    /// What the validation error of ``aValidationErrorIsAUsageError()`` says.
    private static let validationMessage = "the run needs an agent command after \"--\""

    /// The directories whose files may hold no exit code number of their own.
    ///
    /// Both targets of the command-line client are read, so the table cannot
    /// be copied into the thin executable either.
    private static let scannedDirectories = RepositoryFile.commandLineClientDirectories

    @Test("every exit code carries its section 9 number")
    func everyExitCodeCarriesItsSectionNineNumber() throws {
        #expect(
            AcpClientExitCode.allCases.count == Self.sectionNineTable.count,
            """
            AcpClientExitCode must hold one case for each row of cli-plan.md \
            section 9, and no other. It holds \(AcpClientExitCode.allCases.count) \
            against \(Self.sectionNineTable.count) rows.
            """
        )
        for code in AcpClientExitCode.allCases {
            let expected = try #require(
                Self.sectionNineTable[code],
                "AcpClientExitCode.\(code) is not a row of the cli-plan.md section 9 table."
            )
            #expect(
                code.rawValue == expected,
                """
                AcpClientExitCode.\(code) must exit \(expected) by cli-plan.md \
                section 9. It exits \(code.rawValue).
                """
            )
        }
    }

    @Test("every stop reason maps to the exit code section 9 owes it")
    func everyStopReasonMapsToItsSectionNineCode() {
        #expect(
            Self.stopReasonRows.count == Self.stopReasonCaseCount,
            """
            StopReason carries \(Self.stopReasonCaseCount) cases, so this test \
            must state that many rows. It states \(Self.stopReasonRows.count).
            """
        )
        for row in Self.stopReasonRows {
            #expect(
                AcpClientExitCode.forStopReason(row.reason) == row.code,
                """
                A turn that stopped for \(row.reason) must exit \(row.code.rawValue). \
                It exits \(AcpClientExitCode.forStopReason(row.reason).rawValue).
                """
            )
        }
    }

    @Test("an idle that reports no stop reason is a completed turn")
    func anIdleThatReportsNoStopReasonIsACompletedTurn() {
        let idle = IdleStateUpdate()
        #expect(
            idle.stopReason == nil,
            "IdleStateUpdate must let a turn end with no stop reason at all."
        )
        #expect(
            AcpClientExitCode.idleWithNoReason == AcpClientExitCode.forStopReason(.endTurn),
            """
            An idle that reports no stop reason is a turn that ended, so it must \
            exit what an end_turn exits.
            """
        )
    }

    @Test("every doctor status maps to the exit code section 9 owes it")
    func everyDoctorStatusMapsToItsSectionNineCode() {
        for row in Self.doctorStatusRows {
            #expect(
                AcpClientExitCode.forDoctorStatus(row.status) == row.code,
                """
                A doctor report whose worst finding is \(row.status) must exit \
                \(row.code.rawValue). It exits \
                \(AcpClientExitCode.forDoctorStatus(row.status).rawValue).
                """
            )
        }
    }

    @Test("a validation error is a usage error")
    func aValidationErrorIsAUsageError() {
        #expect(
            AcpClientExitCode.forError(ValidationError(Self.validationMessage)) == .usage,
            """
            An ArgumentParser validation error is a mistake in the command line, \
            which cli-plan.md section 9 exits 2.
            """
        )
    }

    @Test("the timeout marker is the timeout exit code")
    func theTimeoutMarkerIsTheTimeoutExitCode() {
        #expect(
            AcpClientExitCode.forError(AcpClientTimeout()) == .timeout,
            """
            AcpClientTimeout is what --timeout throws, and cli-plan.md section 9 \
            exits it 124 to match the timeout(1) convention.
            """
        )
    }

    @Test("a spawn failure is a plain failure")
    func aSpawnFailureIsAPlainFailure() {
        #expect(
            AcpClientExitCode.forError(AgentProcessError.agentUnavailable) == .failure,
            """
            A spawn, protocol or I/O failure is not a usage mistake and not a \
            timeout, so cli-plan.md section 9 exits it 1.
            """
        )
    }

    @Test("no file outside ExitCode.swift spells an exit code number")
    func noFileOutsideTheTableSpellsAnExitCodeNumber() throws {
        let files = try RepositoryFile.swiftSourceFiles(underAnyOf: Self.scannedDirectories)
        try #require(
            !files.isEmpty,
            "The scan found no Swift files below \(Self.scannedDirectories)."
        )
        try #require(
            files.contains { $0.lastPathComponent == ExitCodeLiteralScan.tableFileName },
            """
            The scan expects \(ExitCodeLiteralScan.tableFileName) to stand in \
            \(Self.scannedDirectories) as the file that owns the table.
            """
        )
        let literals = try files
            .filter { $0.lastPathComponent != ExitCodeLiteralScan.tableFileName }
            .flatMap { try ExitCodeLiteralScan.literals(in: $0) }
        #expect(
            literals.isEmpty,
            """
            \(ExitCodeLiteralScan.tableFileName) owns every number of the \
            cli-plan.md section 9 table, so each of these lines must name a case \
            of AcpClientExitCode instead: \(literals).
            """
        )
    }
}
