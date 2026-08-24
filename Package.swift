// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FoundationModelsACPClient",
    // macOS only, matching the family floor (macOS 27 / FoundationModels v2).
    // There is no `@available` branching in this package.
    platforms: [
        .macOS("27.0")
    ],
    products: [
        // The ACP Client role: an observable container that a UI layer can
        // bind to. This library knows the ACP wire, Observation, and the
        // family leaf `FoundationModelsExtras`.
        .library(name: "FoundationModelsACPClient", targets: ["FoundationModelsACPClient"])
    ],
    dependencies: [
        // These two are the whole external dependency list of this package,
        // by design (plan.md, "a client, not *our* client"). Each pin is
        // `branch: "main"` over the SSH URL, matching how every sibling in
        // this family pins an in-family package. A version requirement would
        // conflict for an app that depends on this package and on another
        // in-family consumer at the same time.
        //
        // The ACP wire.
        .package(
            url: "git@github.com:swissarmyhammer/FoundationModelsACP.git",
            branch: "main"
        ),
        // The family leaf that owns `ProcessRegistry`, its `sweep(_:)`, and
        // the `atexit`-installed `ProcessRegistry.global`. Taking the shared
        // type is what makes every consumer in one host process share one
        // registry and one sweep, rather than each package sweeping a global
        // of its own.
        .package(
            url: "git@github.com:swissarmyhammer/FoundationModelsExtras.git",
            branch: "main"
        ),
    ],
    targets: [
        // The library target. It must not import FoundationModelsRouter,
        // FoundationModelsACPAgent, FoundationModelsMCP, the FoundationModels
        // framework, or SwiftUI. A test scans `Sources/` and fails on each
        // forbidden import.
        .target(
            name: "FoundationModelsACPClient",
            dependencies: [
                .product(name: "FoundationModelsACP", package: "FoundationModelsACP"),
                .product(name: "FoundationModelsExtras", package: "FoundationModelsExtras"),
            ]
        ),
        // Tests, on Swift Testing. The suite holds the linkage smoke test and
        // the forbidden-import scanner.
        //
        // This manifest declares no integration test target, and that is the
        // whole unit/integration split. The agent-process suite is its own
        // package, `IntegrationTests/Package.swift`, which depends on this
        // one by path. So `swift test` here runs the unit tests and nothing
        // else — not because a person remembered a flag, but because SwiftPM
        // cannot see a target this manifest does not declare. Run that suite
        // with `swift test --package-path IntegrationTests`.
        .testTarget(
            name: "FoundationModelsACPClientTests",
            dependencies: [
                "FoundationModelsACPClient",
                .product(name: "FoundationModelsACP", package: "FoundationModelsACP"),
                .product(name: "FoundationModelsExtras", package: "FoundationModelsExtras"),
            ]
        ),
    ]
)
