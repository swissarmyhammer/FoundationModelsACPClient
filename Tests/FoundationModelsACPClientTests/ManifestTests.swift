import Foundation
import Testing

/// Pins the parts of `Package.swift` that keep this package a library.
///
/// A build catches most manifest mistakes on its own. It cannot catch these,
/// because each one still builds: an executable product, which makes this
/// package an application; a forbidden module on the library target; a
/// telemetry API that the library target does not link; and a telemetry
/// backend on any target, which puts an exporter into each host process.
///
/// Every rule reads the manifest through `swift package dump-package`, which
/// parses `Package.swift` and writes each declaration in one normal form.
/// SwiftPM accepts five spellings for a `Target.Dependency` — a bare string
/// literal, `.byName(name:)`, `.target(name:)`, `.product(name:package:)`, and
/// the last three with a trailing `moduleAliases:` or `condition:` — and the
/// dump reduces all five to a name under one of three keys. So no rule here
/// has to know which spelling a person wrote, and none of them has to step
/// over a `/* */` comment, a raw string or an `#if os(macOS)` block either.
///
/// Two rules come from the OpenTelemetry design of 2026-09-28. Rule 1 gives
/// the library target the `Tracing`, `Logging` and `Metrics` APIs and no
/// backend. The host application bootstraps a backend, and this package links
/// none.
@Suite("Package manifest")
struct ManifestTests {
    /// The library target of the manifest: the ACP Client role that a UI
    /// layer binds to.
    private static let libraryTargetName = "FoundationModelsACPClient"

    /// The product name of each telemetry API the library target must link.
    /// Each one is an API only, with no backend.
    private static let telemetryAPIProductNames: Set<String> = [
        "Tracing",
        "Logging",
        "Metrics",
    ]

    /// The package name and the product name of the swift-otel backend. No
    /// target of this package may name one of them.
    private static let telemetryBackendNames: Set<String> = [
        "swift-otel",
        "OTel",
    ]

    @Test("the manifest declares the library product and no executable")
    func theManifestDeclaresOnlyTheLibraryProduct() throws {
        let dump = try Self.packageDump()
        #expect(
            dump.products.map(\.name) == [Self.libraryTargetName],
            """
            Package.swift must declare the \(Self.libraryTargetName) library as \
            its one product. It declares \(dump.products.map(\.name).sorted()).
            """
        )
        let hasAnExecutable = dump.products.contains { $0.isExecutable }
        #expect(!hasAnExecutable, "This package is a library, so it must declare no executable product.")
    }

    @Test("the library target names no forbidden module")
    func theLibraryTargetNamesNoForbiddenModule() throws {
        let named = try Self.target(named: Self.libraryTargetName).allNames
        #expect(
            named.isDisjoint(with: forbiddenModules),
            """
            The \(Self.libraryTargetName) target may name none of \
            \(forbiddenModules.sorted()). \
            It names \(named.intersection(forbiddenModules).sorted()).
            """
        )
    }

    @Test("the library target links the Tracing, Logging and Metrics APIs")
    func theLibraryTargetLinksTheTelemetryAPIs() throws {
        let library = try Self.target(named: Self.libraryTargetName)
        #expect(
            Self.telemetryAPIProductNames.isSubset(of: Set(library.productNames)),
            """
            The \(Self.libraryTargetName) target must name each of \
            \(Self.telemetryAPIProductNames.sorted()) as a product dependency. \
            It names \(library.productNames.sorted()).
            """
        )
    }

    @Test("no target names the swift-otel backend")
    func noTargetNamesTheTelemetryBackend() throws {
        // Every target of the manifest, the test target too. A library or a
        // test target that links the backend puts an exporter into a process
        // that did not ask for one.
        let offenders = try Self.packageDump().targets
            .filter { !$0.allNames.isDisjoint(with: Self.telemetryBackendNames) }
            .map(\.name)
        #expect(
            offenders.isEmpty,
            """
            No target may name any of \(Self.telemetryBackendNames.sorted()). \
            These targets name one: \(offenders.sorted()).
            """
        )
    }

    /// One target of the manifest, by name.
    ///
    /// - Parameter name: the target name the manifest declares.
    /// - Returns: that target, with its dependency entries.
    /// - Throws: an error when the manifest cannot be read, or when it declares
    ///   no target of that name.
    private static func target(named name: String) throws -> DumpedTarget {
        let dump = try packageDump()
        return try #require(
            dump.targets.first { $0.name == name },
            """
            Package.swift must declare a target named "\(name)". \
            It declares \(dump.targets.map(\.name).sorted()).
            """
        )
    }

    /// Reads this repository's manifest through `swift package dump-package`.
    ///
    /// SwiftPM parses `Package.swift` and writes every dependency entry in one
    /// normal form, which is why this suite runs the command instead of
    /// reading Swift source text. A reader written by hand has to know string
    /// literals, `//` comments, `/* */` comments, nested block comments, raw
    /// strings, multi-line strings and `#if` blocks before it can find the
    /// entries at all, and SwiftPM already knows every one of them.
    ///
    /// `--scratch-path` is what lets the command run from inside a `swift test`
    /// run of this same package. The DEFAULT scratch path is `.build`, and the
    /// parent run holds a lock on that directory for the whole of its life, so
    /// a child that took the default would wait for a parent that is waiting
    /// for it. Pointed at a fresh temporary directory the child contends with
    /// nothing. Measured on 2026-09-04 from inside this suite: exit 0 in about
    /// 0.2 seconds, over 6165 bytes of manifest JSON, and six copies started
    /// together each answered the same in 0.24 seconds of wall clock.
    ///
    /// This is still a unit test. The child reads this repository's own
    /// manifest with the toolchain that is already running the suite: no
    /// network, no database, no spawned server and no external service.
    ///
    /// - Returns: the manifest SwiftPM parsed.
    /// - Throws: an error when the command cannot run, when it exits nonzero,
    ///   or when the JSON it wrote does not decode.
    private static func packageDump() throws -> PackageDump {
        let root = try RepositoryFile.url(relativePath: "Package.swift")
            .deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-client-library-dump-package-\(UUID().uuidString)")
        // The child writes a scratch directory of its own under here, and the
        // two captured streams stand beside it, so one removal cleans up all
        // three.
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let manifestJSON = try dumpPackage(at: root, workingIn: workingDirectory)
        return try JSONDecoder().decode(PackageDump.self, from: manifestJSON)
    }

    /// Runs `swift package dump-package` over one package.
    ///
    /// The two output streams are captured into files rather than into pipes.
    /// A pipe holds a bounded buffer, so a reader that drains one stream to
    /// end-of-file while the other fills its buffer waits for a child that is
    /// waiting for the reader. A file has no such buffer.
    ///
    /// Every `SWIFTPM`-prefixed variable comes out of the child's environment.
    /// The parent `swift test` run exports the paths it is working in, and an
    /// inherited one would put the child back on `.build` — the very lock
    /// `--scratch-path` is passed to avoid.
    ///
    /// - Parameters:
    ///   - root: the directory holding the `Package.swift` to read.
    ///   - workingDirectory: a directory this call owns. It is created here and
    ///     removed by the caller.
    /// - Returns: the manifest JSON the command wrote to standard output.
    /// - Throws: an error when the directory cannot be made, when the command
    ///   cannot run, when it exits nonzero, or when its output cannot be read.
    private static func dumpPackage(at root: URL, workingIn workingDirectory: URL) throws -> Data {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let manifestJSON = workingDirectory.appendingPathComponent("manifest.json")
        let diagnostics = workingDirectory.appendingPathComponent("diagnostics.txt")
        fileManager.createFile(atPath: manifestJSON.path, contents: nil)
        fileManager.createFile(atPath: diagnostics.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift", "package", "dump-package",
            "--package-path", root.path,
            "--scratch-path", workingDirectory.appendingPathComponent("scratch").path,
        ]
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("SWIFTPM") }
        let output = try FileHandle(forWritingTo: manifestJSON)
        let errors = try FileHandle(forWritingTo: diagnostics)
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        try output.close()
        try errors.close()
        let said = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? ""
        try #require(
            process.terminationStatus == 0,
            """
            `swift package dump-package` must read the manifest at \(root.path). \
            It exited \(process.terminationStatus) and said: \(said)
            """
        )
        return try Data(contentsOf: manifestJSON)
    }

    /// The manifest as `swift package dump-package` writes it.
    private struct PackageDump: Decodable {
        /// One entry for each product the manifest declares.
        let products: [DumpedProduct]

        /// One entry for each target the manifest declares.
        let targets: [DumpedTarget]
    }

    /// One product of the manifest, as SwiftPM parsed it.
    private struct DumpedProduct: Decodable {
        /// The product name a depending package writes.
        let name: String

        /// The kind SwiftPM read this product as.
        let type: Kind

        /// Whether this is an executable product, which another package can
        /// spawn as a binary, rather than a library product, which it can only
        /// import.
        var isExecutable: Bool {
            type.isExecutable
        }

        /// The `type` object of a product.
        ///
        /// SwiftPM names the kind in the KEY and never in the value: an
        /// executable product is written `{"executable": null}` and a library
        /// `{"library": ["automatic"]}`. So the read asks which key stands
        /// there, and decodes no value at all.
        struct Kind: Decodable {
            /// Whether the object carries the `executable` key.
            let isExecutable: Bool

            private enum CodingKeys: String, CodingKey {
                case executable
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isExecutable = container.contains(.executable)
            }
        }
    }

    /// One target of the manifest, as SwiftPM parsed it.
    private struct DumpedTarget: Decodable {
        /// The target name the manifest declares.
        let name: String

        /// One entry for each dependency the target declares, each already in
        /// the one normal form SwiftPM writes.
        let dependencies: [DumpedDependency]

        /// The name in each entry that names a module directly: a bare string
        /// literal, `.byName(name:)`, or `.target(name:)`.
        var targetNames: [String] {
            dependencies.compactMap(\.moduleName)
        }

        /// The product name in each `.product(...)` entry, whatever trailing
        /// `moduleAliases:` or `condition:` argument follows it.
        var productNames: [String] {
            dependencies.compactMap(\.productName)
        }

        /// The package name in each `.product(...)` entry that names one.
        var packageNames: [String] {
            dependencies.compactMap(\.packageName)
        }

        /// Every name the dependency list holds, whichever form the entry is
        /// written in.
        var allNames: Set<String> {
            Set(targetNames + productNames + packageNames)
        }
    }

    /// One dependency entry of a target, as SwiftPM normalises it.
    ///
    /// SwiftPM reads every `Target.Dependency` into one of three cases and
    /// writes each as an object of one key holding that case's arguments:
    ///
    /// - `{"byName": [name, condition]}` — a bare string literal, and
    ///   `.byName(name:)`.
    /// - `{"target": [name, condition]}` — `.target(name:)`.
    /// - `{"product": [name, package, moduleAliases, condition]}` —
    ///   `.product(name:package:)`, whatever trailing argument follows it.
    ///
    /// The first two name a module directly, so they fold into one name here:
    /// every rule of this suite reads the name, and none of them reads the
    /// spelling.
    private struct DumpedDependency: Decodable {
        /// The module this entry names directly, or `nil` where it names a
        /// product.
        let moduleName: String?

        /// The product this entry names, or `nil` where it names a module.
        let productName: String?

        /// The package the product stands in, or `nil` where the entry names
        /// none.
        let packageName: String?

        /// The keys SwiftPM writes a dependency entry under, one for each case
        /// of its own `Target.Dependency`.
        private enum CodingKeys: String, CodingKey {
            case byName
            case target
            case product
        }

        /// The keys whose entry names a module directly.
        private static let moduleKeys: [CodingKeys] = [.byName, .target]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.product) {
                var entry = try container.nestedUnkeyedContainer(forKey: .product)
                moduleName = nil
                productName = try entry.decode(String.self)
                packageName = try entry.decodeIfPresent(String.self)
            } else if let key = Self.moduleKeys.first(where: container.contains) {
                var entry = try container.nestedUnkeyedContainer(forKey: key)
                moduleName = try entry.decode(String.self)
                productName = nil
                packageName = nil
            } else {
                // A key outside those three is a dependency form no rule of
                // this suite could hold against, so the read FAILS on it. A
                // reader that dropped it would be blind to that form, and
                // every rule that reads a dependency list would be evadable by
                // writing one entry in it.
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: """
                            SwiftPM wrote a target dependency under no key this reader knows. \
                            It knows \(Self.moduleKeys.map(\.stringValue)) and \
                            \(CodingKeys.product.stringValue).
                            """
                    )
                )
            }
        }
    }
}
