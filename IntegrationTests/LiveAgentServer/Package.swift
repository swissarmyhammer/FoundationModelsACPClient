// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The name of this package.
private let packageName = "LiveAgentServer"

/// The name of the executable product and target of the turn test: the real
/// agent with a real model. The integration test of
/// FoundationModelsACPClient builds this product and starts it.
private let serverProductName = "live-agent-server"

/// The name of the executable product and target of the GraphQL test: the
/// real agent with its GraphQL tunnel, the stub model path, and a small
/// test endpoint. The integration test builds this product and starts it.
private let graphQLServerProductName = "graphql-tunnel-server"

/// The name of the library target that the two servers share: the launch
/// arguments and the home of the agent.
private let supportTargetName = "LiveAgentServerSupport"

/// The base URL of the packages of the swissarmyhammer GitHub organization,
/// as the root manifest declares them.
private let swissArmyHammerOrgURL = "git@github.com:swissarmyhammer/"

/// The branch of each family package, as the root manifest declares it.
private let mainBranch = "main"

/// The ACP wire: the stdio transport and the agent side of the connection.
private let wirePackageName = "FoundationModelsACP"

/// The real agent: `RoutedACPAgent`, `ComposedAgent` and the GraphQL tunnel.
private let agentPackageName = "FoundationModelsACPAgent"

/// The runtime of the agent: the router that loads the real model with
/// greedy decoding.
private let routerPackageName = "FoundationModelsRouter"

/// The family leaf: the GraphQL endpoint protocol of the test endpoint.
private let extrasPackageName = "FoundationModelsExtras"

/// The family packages that the servers link. Each one ships a library
/// product with the name of its package.
private let familyPackageNames = [wirePackageName, agentPackageName, routerPackageName, extrasPackageName]

/// The GraphQL engine package. The test endpoint takes its `Map` values. The
/// URL and the floor are the pin of FoundationModelsExtras, which owns the
/// GraphQL toolkit of the family.
private let graphQLPackageURL = "https://github.com/GraphQLSwift/GraphQL.git"

/// The lowest GraphQL version, as FoundationModelsExtras declares it.
private let graphQLFloor: Version = "4.3.0"

/// The name of the GraphQL package and of its library product.
private let graphQLPackageName = "GraphQL"

/// The products of the family packages, by package name.
///
/// - Parameter names: The package names.
/// - Returns: The library product of each package.
private func familyProducts(_ names: [String]) -> [Target.Dependency] {
    names.map { name in .product(name: name, package: name) }
}

/// SwiftPM manifest for the agent servers of the integration test of
/// FoundationModelsACPClient.
///
/// This package is NOT in the graph of the `IntegrationTests` package. The
/// test builds each server with `swift build --package-path` and starts the
/// executable as an external agent over stdio.
///
/// The reason is the SwiftPM warning "Conflicting identity for
/// foundationmodelsacpclient". FoundationModelsACPAgent depends on
/// FoundationModelsACPClient by URL, for its executables and its test
/// support. The `IntegrationTests` package depends on the local library by
/// path. SwiftPM checks each dependency of each product of a package, not
/// only the dependencies of the product in use. Thus each graph that holds
/// the agent package and the local library by path gives the warning. This
/// graph holds the agent package and no path dependency, so it gives no
/// warning. The server links only the library product of the agent package,
/// and that product does not link the client. The test is the only client,
/// and it uses the local library.
let package = Package(
    name: packageName,
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: serverProductName, targets: [serverProductName]),
        .executable(name: graphQLServerProductName, targets: [graphQLServerProductName]),
    ],
    dependencies: familyPackageNames.map { name in
        .package(url: "\(swissArmyHammerOrgURL)\(name).git", branch: mainBranch)
    } + [
        .package(url: graphQLPackageURL, from: graphQLFloor)
    ],
    targets: [
        .target(
            name: supportTargetName,
            dependencies: familyProducts([agentPackageName]),
            path: "Sources/\(supportTargetName)"
        ),
        .executableTarget(
            name: serverProductName,
            dependencies: [.target(name: supportTargetName)]
                + familyProducts([wirePackageName, agentPackageName, routerPackageName]),
            path: "Sources/\(serverProductName)"
        ),
        .executableTarget(
            name: graphQLServerProductName,
            dependencies: [.target(name: supportTargetName)]
                + familyProducts([wirePackageName, agentPackageName, extrasPackageName])
                + [.product(name: graphQLPackageName, package: graphQLPackageName)],
            path: "Sources/\(graphQLServerProductName)"
        ),
    ]
)
