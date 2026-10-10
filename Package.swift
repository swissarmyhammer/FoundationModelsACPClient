// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FoundationModelsACPClient",
    // The language of the string catalog of the library target. A bundle
    // gives this localization when it has no localization for the language
    // of the user.
    defaultLocalization: "en",
    // macOS only, matching the family floor (macOS 27 / FoundationModels v2).
    // There is no `@available` branching in this package.
    platforms: [
        .macOS("27.0")
    ],
    products: [
        // The ACP Client role: an observable container that a UI layer can
        // bind to. This library knows the ACP wire, Observation, the family
        // leaf `FoundationModelsExtras`, and the Tracing, Logging and Metrics
        // APIs. It is the only product: this package is a library, and not an
        // application.
        .library(name: "FoundationModelsACPClient", targets: ["FoundationModelsACPClient"]),
    ],
    dependencies: [
        // The first two are the whole in-family dependency list of this
        // package, by design: a client that knows only ACP can drive any
        // conforming agent, so this package must not depend on the agent
        // runtime. Each pin is `branch: "main"` over the SSH URL, matching how
        // every sibling in this family pins an in-family package. A version
        // requirement would conflict for an app that depends on this package
        // and on another in-family consumer at the same time.
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
        // The tracing API, the logging API and the metrics API of the library
        // target (the OpenTelemetry design of 2026-09-28). API only: this
        // package links no backend and bootstraps none. The host application
        // bootstraps a backend. Until it does, each span, each logger and each
        // metric of the library does nothing. The floors are the floors of
        // `FoundationModelsExtras`, which already puts these three packages
        // into the graph.
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.4.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.11.0"),
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
                // The names of `ACPClientTelemetry` go to these three APIs.
                // `ManifestTests` checks that the library links all three.
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ],
            // The string catalog of the texts that the library gives a UI,
            // for example `AuthFailure.Reason.message`. A host app translates
            // these texts with no change to the code.
            resources: [.process("Localizable.xcstrings")]
        ),
        // Tests, on Swift Testing. Each test runs in process: an agent is an
        // in-memory transport or a scripted stub, and no test spawns a client.
        .testTarget(
            name: "FoundationModelsACPClientTests",
            dependencies: [
                "FoundationModelsACPClient",
                .product(name: "FoundationModelsACP", package: "FoundationModelsACP"),
                .product(name: "FoundationModelsExtras", package: "FoundationModelsExtras"),
                // The in-memory tracer, log handler and metrics factory of the
                // family, and the content-safety check that reads them.
                .product(name: "TelemetryTestSupport", package: "FoundationModelsExtras"),
                // The request metric tests read the counts and the durations
                // of each metric from the test metrics factory of a capture.
                .product(name: "MetricsTestKit", package: "swift-metrics"),
            ]
        ),
    ]
)
