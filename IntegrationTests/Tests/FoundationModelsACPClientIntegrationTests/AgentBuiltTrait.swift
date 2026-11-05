import Foundation
import Testing

/// A suite trait that builds the products of the `LiveAgentServer` package
/// before the tests of the suite run.
///
/// The build is outside the `.timeLimit` of each test: the trait wraps the
/// whole suite, and the time limit is on the test. Thus a cold build, which is
/// slow on a CI runner, does not count against the time of the first test.
struct AgentBuiltTrait: SuiteTrait, TestScoping {
    /// The executable products that the suite needs.
    let productNames: [String]

    /// The trait wraps the suite one time, and not each test. The scope of
    /// the suite is outside the `.timeLimit` of each test.
    let isRecursive = false

    /// Builds the products, and then runs the test or the suite.
    ///
    /// - Parameters:
    ///   - test: The test or the suite.
    ///   - testCase: The case of the test, or `nil` for a suite.
    ///   - function: The test body.
    /// - Throws: The error of a build, or of the test body.
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let root = try IntegrationTemporaryDirectory.make(prefix: "acp-client-agent-build")
        defer { try? FileManager.default.removeItem(at: root) }
        for productName in productNames {
            _ = try await LiveAgentServerBuild(rootDirectory: root).makeExecutable(productName)
        }
        try await function()
    }
}

extension Trait where Self == AgentBuiltTrait {
    /// The suite builds `acp-agent-stub` before its tests run.
    static var acpAgentStubBuilt: Self {
        AgentBuiltTrait(productNames: [LiveAgentServerBuild.acpAgentStub])
    }
}
