import Foundation
import Testing

/// Tests that the `acp-client` entry point bootstraps telemetry before it does
/// any other work.
///
/// Rule 6 of the OpenTelemetry design of 2026-09-28: an executable must always
/// bootstrap logging. The default handler of swift-log writes to standard
/// output, and `cli-plan.md` §8 keeps standard output for the answer text
/// alone. A log record that a library writes before the bootstrap goes to that
/// default handler, so the bootstrap must be the first statement of `main()`.
///
/// No unit test can import the executable target, and a run of the binary
/// cannot see the order when no code logs before the turn. So this suite reads
/// the source of the entry point.
@Suite("acp-client telemetry bootstrap source")
struct TelemetryBootstrapSourceTests {
    /// The repository-relative path of the file that holds the `@main` type.
    private static let entryPointPath = "Sources/acp-client/AcpClientMain.swift"

    /// The text that opens the body of the entry point.
    private static let mainOpening = "static func main() async {"

    /// The statement that must come first in the body of the entry point.
    private static let bootstrapStatement = "TelemetryBootstrap.bootstrap()"

    @Test("main() bootstraps telemetry before any other statement")
    func mainBootstrapsTelemetryFirst() throws {
        let source = try RepositoryFile.read(relativePath: Self.entryPointPath)
        let body = try #require(
            SwiftSourceText.body(openedBy: Self.mainOpening, in: source),
            "\(Self.entryPointPath) must hold `\(Self.mainOpening)` and a closing brace."
        )
        let statements = SwiftSourceText.statementLines(of: body)
        #expect(
            statements.first == Self.bootstrapStatement,
            """
            The first statement of main() must be `\(Self.bootstrapStatement)`. \
            The statements are \(statements).
            """
        )
    }
}
