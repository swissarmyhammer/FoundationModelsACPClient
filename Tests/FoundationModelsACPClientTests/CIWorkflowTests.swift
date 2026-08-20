import Foundation
import Testing

/// Pins the shipped CI workflow to running the integration suite.
///
/// `.github/workflows/ci.yml` has one job, `unit`, that calls the shared
/// `swift-ci.yaml` workflow. That shared workflow only builds and runs the
/// nested `IntegrationTests` package when the caller sets its
/// `integration-package-path` input — an unset input silently drops the
/// integration suite from every CI run, with no red mark anywhere in the
/// workflow file itself. This suite makes sure the `unit` job sets that
/// input to `IntegrationTests`, so a later edit cannot drop it without a red
/// unit test. The ordering after the unit job, and the compile coupling that
/// keeps these tests from rotting unnoticed, both live inside the shared
/// workflow now, out of this repository's reach — this suite pins only what
/// this repository still controls.
@Suite("CI workflow")
struct CIWorkflowTests {
    @Test("the unit job sets integration-package-path to IntegrationTests")
    func unitJobSetsIntegrationPackagePath() throws {
        let block = try Self.jobBlock(named: "unit")
        let setsThePackagePath = block.contains { line in
            line.trimmingCharacters(in: .whitespaces) == "integration-package-path: IntegrationTests"
        }
        #expect(
            setsThePackagePath,
            """
            The unit job in .github/workflows/ci.yml must set \
            \"integration-package-path: IntegrationTests\", or the shared \
            swift-ci.yaml workflow silently skips the integration suite.
            """
        )
    }

    /// The indentation of a job's own keys (`uses:`, `with:`, and the keys
    /// nested under `with:`). A content line with less indentation opens the
    /// next job or the next top-level key, so it ends the current job block.
    private static let jobKeyIndentation = "    "

    /// Reads `.github/workflows/ci.yml` from the repository root through
    /// `RepositoryFile.read(relativePath:)`.
    ///
    /// - Returns: each line of the workflow file.
    /// - Throws: an error when the file cannot be read.
    private static func workflowLines() throws -> [Substring] {
        let text = try RepositoryFile.read(relativePath: ".github/workflows/ci.yml")
        return text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Collects the lines of one job block: the lines under the job's own
    /// key, up to the next content line that stands outside the job.
    ///
    /// - Parameter name: the job key, for example `"unit"`.
    /// - Returns: every line inside that job's block.
    /// - Throws: `CIWorkflowTestsError` when the workflow holds no job with
    ///   that name.
    private static func jobBlock(named name: String) throws -> [Substring] {
        let lines = try Self.workflowLines()
        let jobKey = "  \(name):"
        guard let jobKeyIndex = lines.firstIndex(of: Substring(jobKey)) else {
            throw CIWorkflowTestsError(message: "ci.yml has no job named \"\(name)\".")
        }

        var block: [Substring] = []
        for line in lines[lines.index(after: jobKeyIndex)...] {
            if Self.endsJobBlock(line) { break }
            block.append(line)
        }
        return block
    }

    /// Tells whether a line ends a job block. A blank line and a comment
    /// line continue the block. A content line with less indentation than a
    /// job key ends it.
    private static func endsJobBlock(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        return !line.hasPrefix(Self.jobKeyIndentation)
    }
}

/// A parse failure reading `.github/workflows/ci.yml`.
private struct CIWorkflowTestsError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
