import ArgumentParser
import Testing

@testable import AcpClientCore

/// Pins the one version constant the binary reports, and with it the fact that
/// the library holding the command-line client is importable at all.
///
/// A target whose sources hold top-level code cannot be imported at all,
/// testably or not, so the `import AcpClientCore` above is the standing guard
/// on the client staying in a library that no `main.swift` can spoil. Every
/// later unit test of the CLI rests on it.
@Suite("acp-client version")
struct AcpClientVersionTests {
    /// The number of dot-separated numbers a semantic version carries.
    private static let semanticVersionComponentCount = 3

    @Test("the reported version is three dot-separated numbers")
    func theVersionIsThreeDotSeparatedNumbers() {
        let components = AcpClientVersion.current.split(separator: ".")
        #expect(
            components.count == Self.semanticVersionComponentCount,
            """
            AcpClientVersion.current must be a semantic version. \
            It is "\(AcpClientVersion.current)".
            """
        )
        let numbers = components.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        #expect(
            numbers.count == components.count,
            """
            Every component of AcpClientVersion.current must be a number. \
            It is "\(AcpClientVersion.current)".
            """
        )
    }

    /// `--version` is ArgumentParser's own flag, and it answers from
    /// `CommandConfiguration.version`. This pins that the root command hands it
    /// the one constant, so the flag and the constant cannot disagree.
    @Test("the root command reports the version constant")
    func theRootCommandReportsTheVersionConstant() {
        #expect(
            AcpClient.configuration.version == AcpClientVersion.current,
            """
            AcpClient.configuration.version must be AcpClientVersion.current. \
            It is "\(AcpClient.configuration.version)".
            """
        )
    }
}
