import Testing

import acp_client

/// Pins the one version constant the binary reports, and with it the fact that
/// the executable target is importable at all.
///
/// A target whose sources hold top-level code cannot be imported, so the plain
/// `import acp_client` above is the standing guard on `AcpClient.swift` never
/// becoming `main.swift`. Every later unit test of the CLI rests on it.
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
}
