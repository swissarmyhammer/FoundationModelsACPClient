// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The name of this package.
private let packageName = "LiveAgentServer"

/// The name of the one executable product and of its target. The
/// integration test of FoundationModelsACPClient builds this product and
/// starts it.
private let serverProductName = "live-agent-server"

/// The base URL of the packages of the swissarmyhammer GitHub organization,
/// as the root manifest declares them.
private let swissArmyHammerOrgURL = "git@github.com:swissarmyhammer/"

/// The branch of each family package, as the root manifest declares it.
private let mainBranch = "main"

/// The family packages that the server links: the ACP wire (the stdio
/// transport and the agent side of the connection), the real agent
/// (`RoutedACPAgent`), and its runtime (the router that loads the real model
/// with greedy decoding). Each one ships a library product with the name of
/// its package.
private let familyPackageNames = [
    "FoundationModelsACP",
    "FoundationModelsACPAgent",
    "FoundationModelsRouter",
]

/// SwiftPM manifest for the agent server of the integration test of
/// FoundationModelsACPClient.
///
/// This package is NOT in the graph of the `IntegrationTests` package. The
/// test builds it with `swift build --package-path` and starts the
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
        .executable(name: serverProductName, targets: [serverProductName])
    ],
    dependencies: familyPackageNames.map { name in
        .package(url: "\(swissArmyHammerOrgURL)\(name).git", branch: mainBranch)
    },
    targets: [
        .executableTarget(
            name: serverProductName,
            dependencies: familyPackageNames.map { name in
                .product(name: name, package: name)
            },
            path: "Sources/\(serverProductName)"
        )
    ]
)
