import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

/// The smoke test for the package linkage. The test imports this package and
/// the ACP wire together, reads a constant that this package declares with an
/// ACP type, and asserts a trivial fact about it. When this test compiles and
/// passes, the dependency on `FoundationModelsACP` is real, not declared prose.
@Test func packageLinksTheACPWire() {
    #expect(ACPClient.supportedProtocolVersion == ProtocolVersion.v2)
    #expect(ACPClient.supportedProtocolVersion.rawValue == 2)
}
