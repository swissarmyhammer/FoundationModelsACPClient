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
        // bind to. This library knows only the ACP wire and Observation.
        .library(name: "FoundationModelsACPClient", targets: ["FoundationModelsACPClient"])
    ],
    dependencies: [
        // The ACP wire. This is the only external dependency of this package,
        // by design (plan.md, "a client, not *our* client"). The pin is
        // `branch: "main"` over the SSH URL, matching how every sibling in
        // this family pins an in-family package. A version requirement would
        // conflict for an app that depends on this package and on another
        // in-family consumer at the same time.
        .package(
            url: "git@github.com:swissarmyhammer/FoundationModelsACP.git",
            branch: "main"
        )
    ],
    targets: [
        // The library target. It must not import FoundationModelsRouter,
        // FoundationModelsACPAgent, FoundationModelsMCP, the FoundationModels
        // framework, or SwiftUI. A test scans `Sources/` and fails on each
        // forbidden import.
        .target(
            name: "FoundationModelsACPClient",
            dependencies: [
                .product(name: "FoundationModelsACP", package: "FoundationModelsACP")
            ]
        ),
        // Tests, on Swift Testing. The suite holds the linkage smoke test and
        // the forbidden-import scanner.
        .testTarget(
            name: "FoundationModelsACPClientTests",
            dependencies: [
                "FoundationModelsACPClient",
                .product(name: "FoundationModelsACP", package: "FoundationModelsACP"),
            ]
        ),
    ]
)
