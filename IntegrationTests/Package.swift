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
/// compile these files. `.github/workflows/ci.yml` restores the coupling by
/// passing this package's path to the shared `swift-ci.yaml` workflow's
/// `integration-package-path` input: that workflow builds this package in
/// its unit job on every trigger, and runs it in its own integration job,
/// ordered after the unit job internally. `CIWorkflowTests` in the unit
/// suite pins that `ci.yml` sets the input.
///
/// **Why the dependency list below repeats the root manifest's.** A SwiftPM
/// manifest cannot import code from another manifest. A package may only
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
        // Restated verbatim from `../Package.swift`. The doctor vocabulary —
        // `Doctorable`, `HealthCheck` and `HealthStatus` — lives here, and the
        // suite asserts on it directly, so it names where those types come
        // from rather than resting on a transitive import.
        .package(
            url: "git@github.com:swissarmyhammer/FoundationModelsExtras.git",
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
                // The family leaf that owns the doctor vocabulary. The doctor
                // suite asserts on `HealthCheck` and `HealthStatus` values
                // that `AgentCommandDoctor` builds.
                .product(name: "FoundationModelsExtras", package: "FoundationModelsExtras"),
                // Everything the `acp-client` binary does, as a library. A
                // test here can `import AcpClientCore` and drive the client
                // directly, rather than only through the spawned binary.
                //
                // This is why that library exists. SwiftPM emits no importable
                // module for an EXECUTABLE product across a package boundary:
                // while the client lived in the `acp-client` target alone,
                // `import acp_client` failed here at dependency scanning under
                // the default build system, and no `acp_client.swiftmodule`
                // was ever built.
                .product(name: "AcpClientCore", package: "FoundationModelsACPClient"),
                // The `acp-client` executable of the root package
                // (`cli-plan.md` §3). A test target that depends on an
                // EXECUTABLE product makes SwiftPM build that binary into the
                // same products directory as this test bundle, which is where
                // `acpClientBinaryURL()` looks for it. The sibling package
                // FoundationModelsACPAgent declares its own `acp-agent`
                // example this way, for this reason.
                //
                // It brings no new root dependency with it. `acp-client` is a
                // product of the package the list above already reaches by
                // path, so the restatement rule of this manifest's header has
                // nothing to add for it.
                .product(name: "acp-client", package: "FoundationModelsACPClient"),
            ],
            path: "Tests/FoundationModelsACPClientIntegrationTests"
        )
    ]
)
