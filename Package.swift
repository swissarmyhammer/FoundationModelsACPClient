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
        .library(name: "FoundationModelsACPClient", targets: ["FoundationModelsACPClient"]),
        // The command-line client for any ACP v2 agent (cli-plan.md §3). It is
        // a product, and not a target alone, because FoundationModelsACPAgent
        // depends on this package and spawns this binary from its own tests
        // (§17), exactly as this package's own `IntegrationTests` package
        // already spawns `acp-agent`.
        .executable(name: "acp-client", targets: ["acp-client"]),
    ],
    dependencies: [
        // The first two are the whole in-family dependency list of this
        // package, by design (plan.md, "a client, not *our* client"). Each pin
        // is `branch: "main"` over the SSH URL, matching how every sibling in
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
        // The parser for `acp-client` (cli-plan.md §4). The binary writes no
        // parser of its own. `FoundationModelsExtras` already declares this
        // package from the same floor, and the graph resolves it at 1.8.2, so
        // the direct declaration costs no new checkout. It is direct rather
        // than taken through the `Operations` re-export because the binary
        // wants the parser alone, and not the fusion machinery around it.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        // The terminal design system for the stderr layer (cli-plan.md §5).
        // The agent plan picked Noora, and this package follows that decision,
        // because two CLIs in one family that draw tables differently is a
        // defect a user sees.
        //
        // `.upToNextMinor` and not `from:`: Noora is a 0.x package, where
        // `from:` accepts every future 0.x minor, and Noora's release history
        // holds breaking 0.x minors.
        //
        // Noora also pulls `onevcat/Rainbow`, `apple/swift-log` and
        // `tuist/path` into this graph. Those three are the cost, and this
        // comment is where it is visible.
        .package(url: "https://github.com/tuist/Noora.git", .upToNextMinor(from: "0.57.0")),
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
        // The `acp-client` executable (cli-plan.md §3). Its file is
        // `AcpClient.swift` and not `main.swift`, because a target holding
        // top-level code cannot be imported by a test target.
        //
        // These five dependencies are all of them, and §12 permits no more:
        // this package, the wire, the parser, the terminal package, and the
        // family leaf whose `Doctorable`, `DoctorRunner`, `DoctorReport`,
        // `HealthCheck`, `HealthStatus` and `PlainTextDoctorRenderer` the
        // `doctor` subcommand of §10 stands on. None of them is
        // FoundationModelsRouter, FoundationModelsACPAgent,
        // FoundationModelsMCP, the FoundationModels framework, or SwiftUI, and
        // `ManifestTests` reads this block to keep it that way.
        .executableTarget(
            name: "acp-client",
            dependencies: [
                "FoundationModelsACPClient",
                .product(name: "FoundationModelsACP", package: "FoundationModelsACP"),
                .product(name: "FoundationModelsExtras", package: "FoundationModelsExtras"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Noora", package: "Noora"),
            ]
        ),
        // Tests, on Swift Testing. The suite holds the linkage smoke test, the
        // forbidden-import scanner, and the manifest and version tests of the
        // executable. It takes the `acp-client` target so those tests can
        // `import acp_client`.
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
                "acp-client",
                .product(name: "FoundationModelsACP", package: "FoundationModelsACP"),
                .product(name: "FoundationModelsExtras", package: "FoundationModelsExtras"),
            ]
        ),
    ]
)
