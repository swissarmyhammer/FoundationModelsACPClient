import Testing

import AcpClientCore

// This file measures the build graph, and nothing else.
//
// Every other suite in this package spawns a real `acp-client` process and
// reads what it wrote. This one never starts a process. It is here because the
// thing it proves cannot be proved anywhere else: that a target of THIS
// package can name a type of `AcpClientCore` at compile time.
//
// SwiftPM publishes no importable module for an EXECUTABLE product across a
// package boundary. While the CLI lived in the `acp-client` executable target
// alone, `import acp_client` here failed at dependency scanning with
// `unable to resolve module dependency: 'acp_client'`, and no
// `acp_client.swiftmodule` was ever emitted. The health checks the `doctor`
// subcommand needs are driven from this package directly, not through the
// binary, so the CLI had to become a library the binary is thin over.
//
// The `import` line above is the assertion. It compiles only while
// `AcpClientCore` stays a library PRODUCT of the root package, under the
// default build system — `--build-system native` is not used here, and CI
// passes no build-system input either.

/// Pins the library product the root package publishes for this package to
/// import.
@Suite("AcpClientCore across the package boundary")
struct AcpClientCoreImportTests {
    @Test("the imported module reports a semantic version")
    func theImportedModuleReportsASemanticVersion() {
        // `Regex` is not `Sendable`, so the pattern is local rather than a
        // stored constant, matching how the unit suite writes its own.
        let semanticVersion = /[0-9]+\.[0-9]+\.[0-9]+/
        #expect(
            AcpClientVersion.current.wholeMatch(of: semanticVersion) != nil,
            """
            AcpClientCore.AcpClientVersion.current must be three dot-separated \
            numbers. It is "\(AcpClientVersion.current)".
            """
        )
    }
}
