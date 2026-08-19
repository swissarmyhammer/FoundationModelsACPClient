// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The manifest for the integration suite.
///
/// **Why this is a package of its own.** A `swift test` at the repository
/// root must run the unit tests and nothing more. The split must be a
/// property of the build graph, not a convention. SwiftPM gives no
/// manifest-level way to keep a declared target out of the default run.
/// A package that the root manifest does not name is not visible to the
/// root's `swift test`. An environment-variable gate is not permitted here:
/// with a gate, a green run that measured nothing looks the same as a green
/// run that measured everything. Nothing here reads the environment, and
/// nothing may start to do so. The sibling package FoundationModelsMultitool
/// uses the same split, for the same reasons.
///
/// The two commands are:
///
///     swift test                                    # unit tests
///     swift test --package-path IntegrationTests    # this suite
///
/// **The compile coupling this package owes CI.** The root build does not
/// compile these files. `.github/workflows/ci.yml` restores the coupling:
/// the `integration` job builds and runs this package on every trigger,
/// after the `unit` job. `CIWorkflowTests` in the unit suite pins that
/// job order.
///
/// **Why the dependency list below repeats the root manifest's.** A SwiftPM
/// manifest cannot import code from an other manifest. A package may only
/// name the products of the packages it declares itself. Each URL and
/// requirement below matches `../Package.swift` exactly. A mismatch is a
/// resolution conflict, not a second opinion. `../Package.swift` carries
/// the reasons for each dependency; this manifest carries only what SwiftPM
/// needs to resolve them.
let package = Package(
    name: "FoundationModelsACPClientIntegrationTests",
    // Commit to macOS 27, exactly as `../Package.swift` does. A lower floor
    // here would not resolve against it.
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: ".."),
        // Restated verbatim from `../Package.swift`.
        .package(
            url: "git@github.com:swissarmyhammer/FoundationModelsACP.git",
            branch: "main"
        ),
    ],
    targets: [
        // The integration suite. Each test spawns a real foreign-agent
        // process and speaks ACP over its stdio. The tests touch the
        // process table and the file system, so this is the target CI runs
        // in a job of its own.
        .testTarget(
            name: "FoundationModelsACPClientIntegrationTests",
            dependencies: [
                .product(name: "FoundationModelsACPClient", package: "FoundationModelsACPClient"),
                .product(name: "FoundationModelsACP", package: "FoundationModelsACP"),
            ],
            path: "Tests/FoundationModelsACPClientIntegrationTests"
        )
    ]
)
