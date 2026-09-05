import Foundation
import Testing

@testable import AcpClientCore

// These tests read the prose of `cli-plan.md` and `README.md` and compare it with
// the code the prose describes. A plan that disagrees with the code is worse than
// no plan, so each test below pins one statement that a later edit could break on
// one side alone.
//
// Every test reads the shipped document through `RepositoryFile`, which is the one
// place this target navigates to the repository root.

/// Reads one section, and the table rows of one section, out of a Markdown
/// document of this repository.
///
/// The plan is one document of numbered sections, and a test that searched the
/// whole file would read a row of a neighbouring table. So each reading names its
/// section first, and every row a test judges comes from inside it.
private enum PlanSection {
    /// The plan the command-line client is written against.
    static let planPath = "cli-plan.md"

    /// The landing page of this package.
    static let readmePath = "README.md"

    /// The opening of a section heading, at either of the two levels the plan
    /// writes.
    ///
    /// A section runs to the next heading of either level, so `## 6.` ends at
    /// `### 6.1` and `## 9.` ends at `## 10.`.
    static let headingOpenings = ["## ", "### "]

    /// The character a Markdown table writes between two cells.
    static let cellSeparator: Character = "|"

    /// Returns the lines of one section of a Markdown document.
    ///
    /// - Parameters:
    ///   - heading: The opening of the section's own heading line, for example
    ///     `"## 9."`.
    ///   - relativePath: The document's path from the repository root.
    /// - Returns: Each line under that heading, up to the next heading.
    /// - Throws: An expectation failure when the document holds no such heading,
    ///   or whatever reading the document throws.
    static func lines(under heading: String, of relativePath: String) throws -> [Substring] {
        let document = try RepositoryFile.read(relativePath: relativePath)
        let all = document.split(separator: "\n", omittingEmptySubsequences: false)
        let headingIndex = try #require(
            all.firstIndex { $0.hasPrefix(heading) },
            "\(relativePath) holds no heading opening \"\(heading)\"."
        )
        let body = all[all.index(after: headingIndex)...]
        let nextHeading = body.firstIndex { line in
            headingOpenings.contains { line.hasPrefix($0) }
        }
        return Array(body[..<(nextHeading ?? body.endIndex)])
    }

    /// Returns the first cell of each table row among the given lines.
    ///
    /// A Markdown row opens with the cell separator, so the text before the
    /// second separator is the first cell. A line that opens with anything else
    /// is not a row and contributes nothing.
    ///
    /// - Parameter lines: The lines of one section.
    /// - Returns: The trimmed first cell of each row, in the order the rows
    ///   stand.
    static func firstCells(of lines: [Substring]) -> [String] {
        lines
            .filter { $0.hasPrefix(String(cellSeparator)) }
            .compactMap { row in
                row.split(separator: cellSeparator, omittingEmptySubsequences: false)
                    .dropFirst()
                    .first?
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    /// Returns the whole row whose first cell is the given text.
    ///
    /// - Parameters:
    ///   - cell: The first cell to look for, for example `"N5"`.
    ///   - lines: The lines of one section.
    /// - Returns: That row, or `nil` when the section holds no such row.
    static func row(openingWith cell: String, among lines: [Substring]) -> Substring? {
        lines.first { row in
            row.hasPrefix(String(cellSeparator)) && firstCells(of: [row]).first == cell
        }
    }

    /// The character that opens and closes a Markdown code span.
    static let quoteMark: Character = "`"

    /// Returns the name a backtick-quoted table cell holds.
    ///
    /// The plan writes each subcommand name as code, so a cell that carries no
    /// backticks is a heading cell or a separator rather than a name.
    ///
    /// - Parameter cell: One table cell.
    /// - Returns: The text between the backticks, or `nil` when the cell holds
    ///   none.
    static func quotedName(in cell: String) -> String? {
        let backtick = String(quoteMark)
        guard cell.hasPrefix(backtick), cell.hasSuffix(backtick), cell.count > backtick.count else {
            return nil
        }
        return String(cell.dropFirst().dropLast())
    }

    /// Returns the backtick-quoted item of a section whose text ends with the
    /// given suffix.
    ///
    /// The lines are joined first, because Markdown wraps a paragraph and a
    /// code span therefore need not stand whole on one line. In the joined
    /// text the backticks alternate: every second piece of the split is the
    /// inside of a code span, and every other piece is prose.
    ///
    /// - Parameters:
    ///   - suffix: The ending to look for, for example a file name.
    ///   - lines: The lines of one section.
    /// - Returns: The first such code span, or `nil` when the section holds
    ///   none.
    static func quotedItem(endingWith suffix: String, among lines: [Substring]) -> String? {
        let firstCodeSpan = 1
        let piecesForEachCodeSpan = 2
        return lines.joined(separator: " ")
            .split(separator: quoteMark, omittingEmptySubsequences: false)
            .enumerated()
            .first {
                $0.offset % piecesForEachCodeSpan == firstCodeSpan && $0.element.hasSuffix(suffix)
            }
            .map { String($0.element) }
    }
}

/// Pins the statements `cli-plan.md` and `README.md` make about the shipped
/// command-line client.
@Suite("acp-client plan documents")
struct PlanDocumentTests {
    /// The heading of the section that states the permission and elicitation
    /// policy.
    private static let declinePolicyHeading = "### 13.1 Permission and elicitation"

    /// The heading opening of the subcommand section of the plan.
    private static let subcommandHeading = "## 6."

    /// The heading opening of the exit code section of the plan.
    private static let exitCodeHeading = "## 9."

    /// The heading opening of the terminal output section of the plan.
    private static let terminalHeading = "## 5."

    /// The heading opening of the milestone section of the plan.
    private static let milestoneHeading = "## 15."

    /// The milestone the `doctor` subcommand of §10 stands under.
    private static let doctorMilestone = "N5"

    /// The word an unfinished milestone row would carry, in the case a test
    /// compares against.
    private static let blockedWord = "blocked"

    /// The file `cli-plan.md` §5 names as the one importer of the terminal
    /// package.
    private static let terminalFileName = "TerminalOutput.swift"

    /// The name of the binary, which `README.md` must give a reader.
    private static let binaryName = "acp-client"

    @Test("the plan states the permission and elicitation policy")
    func thePlanStatesTheDeclinePolicy() throws {
        let plan = try RepositoryFile.read(relativePath: PlanSection.planPath)
        #expect(
            plan.contains(Self.declinePolicyHeading),
            """
            \(PlanSection.planPath) must hold the section \
            "\(Self.declinePolicyHeading)". A headless binary declines every \
            permission request and every elicitation, and a policy the plan does \
            not state is a policy a reader meets first on standard error.
            """
        )
    }

    @Test("the doctor milestone is no longer blocked")
    func theDoctorMilestoneIsNoLongerBlocked() throws {
        let milestones = try PlanSection.lines(
            under: Self.milestoneHeading,
            of: PlanSection.planPath
        )
        let row = try #require(
            PlanSection.row(openingWith: Self.doctorMilestone, among: milestones),
            """
            \(PlanSection.planPath) section 15 must hold a row for \
            \(Self.doctorMilestone).
            """
        )
        #expect(
            !row.lowercased().contains(Self.blockedWord),
            """
            \(Self.doctorMilestone) is shipped: the Doctorable module of \
            FoundationModelsExtras is written, its main branch is pushed, and this \
            package is resolved against it. The section 15 row must state no block. \
            It reads: \(row)
            """
        )
    }

    @Test("the landing page names the binary")
    func theLandingPageNamesTheBinary() throws {
        let readme = try RepositoryFile.read(relativePath: PlanSection.readmePath)
        #expect(
            readme.contains(Self.binaryName),
            """
            \(PlanSection.readmePath) must name \(Self.binaryName). The package \
            ships a binary as well as a library, and a landing page that names \
            only the library hides half of what a reader can depend on.
            """
        )
    }

    @Test("every subcommand section 6 lists is a subcommand of the parser")
    func everySubcommandSectionSixListsIsDeclared() throws {
        let section = try PlanSection.lines(
            under: Self.subcommandHeading,
            of: PlanSection.planPath
        )
        let documented = Set(PlanSection.firstCells(of: section).compactMap(PlanSection.quotedName))
        let declared = Set(
            try AcpClient.configuration.subcommands.map { subcommand in
                try #require(
                    subcommand.configuration.commandName,
                    "\(subcommand) declares no commandName, so no document can name it."
                )
            }
        )
        #expect(
            documented == declared,
            """
            \(PlanSection.planPath) section 6 and AcpClient.configuration must name \
            the same subcommands, so the document and the parser cannot drift. \
            The document names \(documented.sorted()) and the parser declares \
            \(declared.sorted()).
            """
        )
    }

    @Test("every exit code of section 9 has a case, and every case has a row")
    func theExitCodeTableAndTheExitCodeTypeAgree() throws {
        let section = try PlanSection.lines(
            under: Self.exitCodeHeading,
            of: PlanSection.planPath
        )
        let documented = Set(PlanSection.firstCells(of: section).compactMap { Int32($0) })
        let declared = Set(AcpClientExitCode.allCases.map(\.rawValue))
        #expect(
            documented == declared,
            """
            \(PlanSection.planPath) section 9 and AcpClientExitCode must carry the \
            same exit codes. The table states \(documented.sorted()) and the type \
            carries \(declared.sorted()).
            """
        )
    }

    @Test("section 5 names the terminal file by the path it stands at")
    func sectionFiveNamesTheTerminalFileThatStands() throws {
        let section = try PlanSection.lines(
            under: Self.terminalHeading,
            of: PlanSection.planPath
        )
        let documented = try #require(
            PlanSection.quotedItem(endingWith: Self.terminalFileName, among: section),
            """
            \(PlanSection.planPath) section 5 must name \(Self.terminalFileName) as \
            code, because that is the one file that imports the terminal package.
            """
        )

        let sources = try RepositoryFile.swiftSourceFiles(
            underAnyOf: RepositoryFile.commandLineClientDirectories
        )
        let onDisk = sources
            .compactMap(RepositoryFile.relativePath(of:))
            .filter { $0.hasSuffix("/" + Self.terminalFileName) }
            .sorted()
        #expect(
            onDisk == [documented],
            """
            \(PlanSection.planPath) section 5 must name the terminal file by the \
            path it stands at, and it must be the one such file. The section writes \
            "\(documented)", and \(RepositoryFile.commandLineClientDirectories) \
            holds \(onDisk). A file that moves between the two source directories \
            leaves the plan naming a directory that no longer holds it, which is \
            the drift this test exists to catch.
            """
        )
    }
}
