// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The root package that this package tests. This package reaches it by path.
private let rootPackageName = "FoundationModelsACPClient"

/// The name of this package and of its one test target.
private let integrationTargetName = "\(rootPackageName)IntegrationTests"

/// The base URL of the packages of the swissarmyhammer GitHub organization,
/// as the root manifest declares them.
private let swissArmyHammerOrgURL = "git@github.com:swissarmyhammer/"

/// The branch of each family package, as the root manifest declares it.
private let mainBranch = "main"

/// The ACP wire. The test makes the in-memory transport pair, the agent side
/// of the connection and the requests with it.
private let wireDependencyName = "FoundationModelsACP"

/// The real agent. The test runs `RoutedACPAgent` of its library in this
/// process.
private let agentDependencyName = "FoundationModelsACPAgent"

/// The runtime of the agent. The test makes the router that loads the real
/// model, with greedy decoding. Its test-support product gives
/// `MetalLibraryTestBootstrap`, which lets MLX find its shader library under
/// a plain `swift test`.
private let routerDependencyName = "FoundationModelsRouter"

/// Makes the dependency on a family package of `swissArmyHammerOrgURL` that
/// tracks `mainBranch`.
///
/// - Parameter name: The package name, which is also the repository name.
/// - Returns: The package dependency.
private func makeFamilyPackage(name: String) -> Package.Dependency {
    .package(url: "\(swissArmyHammerOrgURL)\(name).git", branch: mainBranch)
}

/// SwiftPM manifest for the integration test of FoundationModelsACPClient.
///
/// This package exists so that `swift test` at the root of the repository
/// runs only the unit tests, as the org test contract (Shape 2 of
/// `swissarmyhammer/workflows` `docs/swift-ci.md`) asks. The root manifest
/// does not name this package. `swift test --package-path IntegrationTests`
/// and the integration job of the shared CI workflow run it. No environment
/// variable selects the test.
///
/// The one test drives `ConnectionModel` and `SessionModel` through the
/// public API of the library, against a real agent with a real model:
///
/// - The agent is `RoutedACPAgent` of FoundationModelsACPAgent, in this
///   process, over an `InMemoryTransport` pair. This is the simplest real
///   agent: there is no binary to build and no process to start. The
///   `acp-agent` executable serves the same agent over stdio.
/// - The model that answers (the `standard` slot) is
///   `mlx-community/Qwen3-4B-4bit`. It is the smallest generation model that
///   the integration suites of FoundationModelsACPAgent load: it is the
///   shipped `flash` slot that `TierThreeFixture` resolves. The router
///   refuses one model for the `standard` slot and the `flash` slot, so the
///   `flash` slot names the smaller `mlx-community/Qwen3-1.7B-4bit`, the
///   same pair as the `agents-demo` example of FoundationModelsAgents.
/// - The router decodes greedy, as `LiveAgent` of FoundationModelsACPAgent
///   does, so that each run gives the same result. The `acp-agent`
///   executable has no greedy option, so the test does not start it.
///
/// SwiftPM writes the warning "Conflicting identity for
/// foundationmodelsacpclient". FoundationModelsACPAgent depends on this
/// library by URL, and this package depends on it by path. SwiftPM uses the
/// path dependency: it makes no checkout of the URL, so the test builds the
/// local library. SwiftPM exempts only a root package from this check, and
/// this package is the root, so each design that puts the agent package in
/// this graph gives the warning.
let package = Package(
    name: integrationTargetName,
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: ".."),
        makeFamilyPackage(name: wireDependencyName),
        makeFamilyPackage(name: agentDependencyName),
        makeFamilyPackage(name: routerDependencyName),
    ],
    targets: [
        .testTarget(
            name: integrationTargetName,
            dependencies: [
                .product(name: rootPackageName, package: rootPackageName),
                .product(name: wireDependencyName, package: wireDependencyName),
                .product(name: agentDependencyName, package: agentDependencyName),
                .product(name: routerDependencyName, package: routerDependencyName),
                .product(name: "\(routerDependencyName)TestSupport", package: routerDependencyName),
            ],
            path: "Tests/\(integrationTargetName)"
        )
    ]
)
