// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The root package that this package tests. This package reaches it by path.
private let rootPackageName = "FoundationModelsACPClient"

/// The name of this package and of its one test target.
private let integrationTargetName = "\(rootPackageName)IntegrationTests"

/// The ACP wire, as the root manifest declares it. The test makes the
/// requests with it.
private let wireDependencyName = "FoundationModelsACP"

/// SwiftPM manifest for the integration test of FoundationModelsACPClient.
///
/// This package exists so that `swift test` at the root of the repository
/// runs only the unit tests, as the org test contract (Shape 2 of
/// `swissarmyhammer/workflows` `docs/swift-ci.md`) asks. The root manifest
/// does not name this package. `swift test --package-path IntegrationTests`
/// and the integration job of the shared CI workflow run it. No environment
/// variable selects the test.
///
/// The tests drive the public API of the library against the real agent,
/// `RoutedACPAgent` of FoundationModelsACPAgent, in a server process of the
/// `LiveAgentServer` package beside this manifest. Each test builds that
/// package, and starts its server over stdio with `AgentProcess` of the
/// library:
///
/// - The turn test drives `ConnectionModel` and `SessionModel` against the
///   `live-agent-server` executable: the agent with greedy decoding and the
///   real model `mlx-community/Qwen3-4B-4bit`. The server holds the
///   configuration of the agent, and tells why it names this model.
/// - The GraphQL tests drive `SAHGraphQLClient` against the
///   `graphql-tunnel-server` executable: the GraphQL tunnel of the agent,
///   the stub model path, and a small test endpoint.
///
/// This graph holds only the local library (by path) and the wire. It must
/// not hold FoundationModelsACPAgent: that package depends on this library by
/// URL, and a graph that holds both gives the SwiftPM warning "Conflicting
/// identity for foundationmodelsacpclient". The manifest of
/// `LiveAgentServer` tells why.
let package = Package(
    name: integrationTargetName,
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "git@github.com:swissarmyhammer/\(wireDependencyName).git", branch: "main"),
    ],
    targets: [
        .testTarget(
            name: integrationTargetName,
            dependencies: [
                .product(name: rootPackageName, package: rootPackageName),
                .product(name: wireDependencyName, package: wireDependencyName),
            ],
            path: "Tests/\(integrationTargetName)"
        )
    ]
)
