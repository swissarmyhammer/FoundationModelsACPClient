import Foundation
import Testing

/// Pins the parts of `Package.swift` and `Package.resolved` that the
/// `acp-client` executable stands on.
///
/// A build catches most manifest mistakes on its own. It cannot catch these
/// five, because each one still builds: an executable declared as a target and
/// not as a product, which no other package can depend on; a dependency the
/// binary must not link, which `cli-plan.md` §12 bans; a sixth dependency past
/// the five that plan permits; a dependency hung on the thin `acp-client`
/// executable target, which reaches around the count the library target
/// carries; and a `from:` requirement on a 0.x package, which accepts every
/// future breaking minor. This suite pins exactly those.
///
/// Every rule but one reads the manifest through `swift package dump-package`,
/// which parses `Package.swift` and writes each declaration in one normal
/// form. SwiftPM accepts five spellings for a `Target.Dependency` — a bare
/// string literal, `.byName(name:)`, `.target(name:)`,
/// `.product(name:package:)`, and the last three with a trailing
/// `moduleAliases:` or `condition:` — and the dump reduces all five to a name
/// under one of three keys. So no rule here has to know which spelling a
/// person wrote, and none of them has to step over a `/* */` comment, a raw
/// string or an `#if os(macOS)` block either. The one rule that still reads
/// the manifest as text is ``theNooraRequirementIsUpToNextMinor``, and it says
/// at its head why the dump cannot answer it.
///
/// The command-line client is two targets, so every rule here says which of
/// them it reads, and why that one and not the other.
@Suite("Package manifest")
struct ManifestTests {
    /// The number of dependencies `cli-plan.md` §12 permits the command-line
    /// client: the library target of this package, and four products.
    ///
    /// They stand on `AcpClientCore` and not on the `acp-client` executable,
    /// because that executable holds the `@main` type alone and reaches every
    /// one of them through the library.
    private static let permittedDependencyCount = 5

    /// The library target of the manifest that carries the dependencies of the
    /// command-line client.
    private static let clientTargetName = "AcpClientCore"

    /// The executable target of the manifest, which holds the `@main` type
    /// alone and takes ``clientTargetName`` as its one dependency
    /// (`cli-plan.md` §3).
    private static let executableTargetName = "acp-client"

    /// The product name of each dependency the binary must link.
    ///
    /// `FoundationModelsExtras` stands here because §10 builds `doctor` on its
    /// `Doctorable`, `DoctorRunner`, `DoctorReport`, `HealthCheck`,
    /// `HealthStatus` and `PlainTextDoctorRenderer`.
    private static let requiredProductNames: Set<String> = [
        "ArgumentParser",
        "Noora",
        "FoundationModelsACP",
        "FoundationModelsExtras",
    ]

    @Test("the manifest declares acp-client as an executable product")
    func theManifestDeclaresTheExecutableProduct() throws {
        let dump = try Self.packageDump()
        let product = try #require(
            dump.products.first { $0.name == Self.executableTargetName },
            """
            Package.swift must declare `.executable(name: "acp-client", ...)`. \
            A target on its own is not enough: FoundationModelsACPAgent depends \
            on this package and spawns this binary from its own tests. \
            It declares the products \(dump.products.map(\.name).sorted()).
            """
        )
        #expect(
            product.isExecutable,
            """
            The \(Self.executableTargetName) product must be an executable \
            product, and SwiftPM read it as a library. A library product \
            publishes a module to import; it is not a binary another package \
            can spawn.
            """
        )
    }

    @Test("the client target links the wire, the parser, the terminal package and the family leaf")
    func theTargetLinksEveryProductTheBinaryNeeds() throws {
        // The library target alone, and not a union with the executable:
        // cli-plan.md §3 gives every one of these links to AcpClientCore, so
        // moving one down to the executable must fail this rule.
        let client = try Self.clientTarget()
        #expect(
            Self.requiredProductNames.isSubset(of: Set(client.productNames)),
            """
            The \(Self.clientTargetName) target must name each of \
            \(Self.requiredProductNames.sorted()) as a product dependency. \
            It names \(client.productNames.sorted()).
            """
        )
    }

    @Test("the client target declares exactly the five dependencies section 12 permits")
    func theTargetDeclaresFiveDependencies() throws {
        // The library target alone. The cap counts where the dependencies
        // stand, and `theExecutableTargetTakesTheLibraryAlone` is what stops a
        // sixth one hiding in the executable instead.
        let client = try Self.clientTarget()
        #expect(
            client.targetNames == ["FoundationModelsACPClient"],
            """
            The \(Self.clientTargetName) target must take this package's own \
            library target, and no other target. \
            It takes \(client.targetNames).
            """
        )
        #expect(
            client.targetNames.count + client.productNames.count
                == Self.permittedDependencyCount,
            """
            cli-plan.md section 12 permits the command-line client five \
            dependencies. \(Self.clientTargetName) declares \
            \(client.targetNames) and \(client.productNames).
            """
        )
    }

    @Test("the acp-client executable target takes the library and nothing else")
    func theExecutableTargetTakesTheLibraryAlone() throws {
        let executable = try Self.executableTarget()
        #expect(
            executable.targetNames == [Self.clientTargetName],
            """
            The \(Self.executableTargetName) executable target holds the @main \
            type alone, so cli-plan.md section 3 gives it \
            \(Self.clientTargetName) as its one dependency and no other target. \
            It takes \(executable.targetNames).
            """
        )
        #expect(
            executable.productNames.isEmpty,
            """
            The \(Self.executableTargetName) executable target must name no \
            package product. Every product the binary needs reaches it through \
            \(Self.clientTargetName), which is where the five that cli-plan.md \
            section 12 permits are counted. It names \
            \(executable.productNames.sorted()).
            """
        )
    }

    @Test("neither target of the command-line client names a forbidden module")
    func neitherTargetNamesAForbiddenModule() throws {
        // Both targets. Section 12 bans these modules from the BINARY, and the
        // binary is the library and the executable together, so reading one of
        // them would leave the other free to name one.
        let named = try Self.clientTarget().allNames
            .union(Self.executableTarget().allNames)
        #expect(
            named.isDisjoint(with: forbiddenModules),
            """
            Neither the \(Self.clientTargetName) target nor the \
            \(Self.executableTargetName) target may name any of \
            \(forbiddenModules.sorted()). \
            They name \(named.intersection(forbiddenModules).sorted()).
            """
        )
    }

    @Test("the Noora requirement is upToNextMinor, not from")
    func theNooraRequirementIsUpToNextMinor() throws {
        // The one rule of this suite that reads the manifest as text, because
        // `swift package dump-package` cannot carry the fact it pins. The dump
        // resolves a requirement to a version RANGE and drops the spelling
        // that wrote it: `.upToNextMinor(from: "0.57.0")` comes back as
        // `[0.57.0, 0.58.0)`, and so would a hand-written half-open range. The
        // rule asks for the spelling, and only the text holds it.
        let manifest = try RepositoryFile.read(relativePath: "Package.swift")
        // `Regex` is not `Sendable`, so the pattern is local rather than a
        // stored constant, matching how `ForbiddenImportTests` writes its own.
        let nooraRequirement =
            /\.package\(\s*url:\s*"[^"]+Noora[^"]*",\s*\.upToNextMinor\(from:\s*"[^"]+"\)\s*\)/
        #expect(
            manifest.contains(nooraRequirement),
            """
            Noora is a 0.x package, where `from:` accepts every future 0.x \
            minor and its release history holds breaking ones. Package.swift \
            must pin it with `.upToNextMinor(from:)`.
            """
        )
    }

    @Test("Package.resolved pins Noora and swift-argument-parser")
    func theResolvedFilePinsTheNewDependencies() throws {
        let identities = try Self.resolvedPackageIdentities()
        #expect(
            identities.contains("noora"),
            "Package.resolved must pin Noora. It pins \(identities.sorted())."
        )
        #expect(
            identities.contains("swift-argument-parser"),
            "Package.resolved must pin swift-argument-parser. It pins \(identities.sorted())."
        )
    }

    /// The ``clientTargetName`` library target, as SwiftPM parsed it.
    ///
    /// - Returns: that target, with its dependency entries.
    /// - Throws: an error when the manifest cannot be read, or when it declares
    ///   no such target.
    private static func clientTarget() throws -> DumpedTarget {
        try target(named: clientTargetName)
    }

    /// The ``executableTargetName`` executable target, as SwiftPM parsed it.
    ///
    /// - Returns: that target, with its dependency entries.
    /// - Throws: an error when the manifest cannot be read, or when it declares
    ///   no such target.
    private static func executableTarget() throws -> DumpedTarget {
        try target(named: executableTargetName)
    }

    /// One target of the manifest, by name.
    ///
    /// One reader serves both targets of the command-line client, so a rule
    /// that must hold on each of them is written once and cannot read one side
    /// only.
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
            .appendingPathComponent("acp-client-dump-package-\(UUID().uuidString)")
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

    /// Reads `Package.resolved` and returns the identity of each pinned package.
    ///
    /// - Returns: the identity SwiftPM derived for each pin.
    /// - Throws: an error when the file cannot be read or does not decode.
    private static func resolvedPackageIdentities() throws -> Set<String> {
        let text = try RepositoryFile.read(relativePath: "Package.resolved")
        let resolved = try JSONDecoder().decode(ResolvedPins.self, from: Data(text.utf8))
        return Set(resolved.pins.map(\.identity))
    }

    /// The `pins` array of `Package.resolved`.
    private struct ResolvedPins: Decodable {
        /// One entry for each package the resolution pinned.
        let pins: [ResolvedPin]
    }

    /// One pin of `Package.resolved`.
    private struct ResolvedPin: Decodable {
        /// The identity SwiftPM derives from the repository name, lowercased.
        let identity: String
    }
}
