import Foundation
import Testing

/// Pins the parts of `Package.swift` and `Package.resolved` that the
/// `acp-client` executable stands on.
///
/// A build catches most manifest mistakes on its own. It cannot catch these
/// four, because each one still builds: an executable declared as a target and
/// not as a product, which no other package can depend on; a dependency the
/// binary must not link, which `cli-plan.md` §12 bans; a sixth dependency past
/// the five that plan permits; and a `from:` requirement on a 0.x package,
/// which accepts every future breaking minor. This suite reads the manifest as
/// text and pins exactly those.
@Suite("Package manifest")
struct ManifestTests {
    /// The number of dependencies `cli-plan.md` §12 permits the `acp-client`
    /// target: the library target of this package, and four products.
    private static let permittedDependencyCount = 5

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
        let manifest = try RepositoryFile.read(relativePath: "Package.swift")
        #expect(
            manifest.contains(#".executable(name: "acp-client""#),
            """
            Package.swift must declare `.executable(name: "acp-client", ...)`. \
            A target on its own is not enough: FoundationModelsACPAgent depends \
            on this package and spawns this binary from its own tests.
            """
        )
    }

    @Test("the acp-client target links the wire, the parser, the terminal package and the family leaf")
    func theTargetLinksEveryProductTheBinaryNeeds() throws {
        let dependencies = try Self.acpClientDependencies()
        #expect(
            Self.requiredProductNames.isSubset(of: Set(dependencies.productNames)),
            """
            The acp-client target must name each of \
            \(Self.requiredProductNames.sorted()) as a product dependency. \
            It names \(dependencies.productNames.sorted()).
            """
        )
    }

    @Test("the acp-client target declares exactly the five dependencies section 12 permits")
    func theTargetDeclaresFiveDependencies() throws {
        let dependencies = try Self.acpClientDependencies()
        #expect(
            dependencies.targetNames == ["FoundationModelsACPClient"],
            """
            The acp-client target must take this package's own library target, \
            and no other target. It takes \(dependencies.targetNames).
            """
        )
        #expect(
            dependencies.targetNames.count + dependencies.productNames.count
                == Self.permittedDependencyCount,
            """
            cli-plan.md section 12 permits the acp-client target five \
            dependencies. It declares \(dependencies.targetNames) and \
            \(dependencies.productNames).
            """
        )
    }

    @Test("the acp-client target names no forbidden module")
    func theTargetNamesNoForbiddenModule() throws {
        let dependencies = try Self.acpClientDependencies()
        let named = Set(
            dependencies.targetNames + dependencies.productNames + dependencies.packageNames
        )
        #expect(
            named.isDisjoint(with: forbiddenModules),
            """
            The acp-client target must name none of \(forbiddenModules.sorted()). \
            It names \(named.intersection(forbiddenModules).sorted()).
            """
        )
    }

    @Test("the Noora requirement is upToNextMinor, not from")
    func theNooraRequirementIsUpToNextMinor() throws {
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

    /// The dependency entries one target of the manifest declares, split by the
    /// form the manifest writes each one in.
    private struct TargetDependencies {
        /// The name in each bare-string entry, which names a target of this
        /// same package.
        let targetNames: [String]

        /// The product name in each `.product(name:package:)` entry.
        let productNames: [String]

        /// The package name in each `.product(name:package:)` entry.
        let packageNames: [String]
    }

    /// Reads `Package.swift` and returns the dependency entries the
    /// `acp-client` executable target declares.
    ///
    /// - Returns: the entries, split by form.
    /// - Throws: an error when the manifest cannot be read, or when it declares
    ///   no `acp-client` executable target.
    private static func acpClientDependencies() throws -> TargetDependencies {
        let manifest = try RepositoryFile.read(relativePath: "Package.swift")
        // The dependency array holds no `]` of its own, so everything up to the
        // first closing bracket is the whole list.
        let dependencyList =
            /\.executableTarget\(\s*name:\s*"acp-client",\s*dependencies:\s*\[(?<entries>[^\]]*)\]/
        let match = try #require(
            manifest.firstMatch(of: dependencyList),
            """
            Package.swift must declare \
            `.executableTarget(name: "acp-client", dependencies: [...])`.
            """
        )
        let entries = String(match.entries)
        let products = entries.matches(of: /\.product\(\s*name:\s*"([^"]+)",\s*package:\s*"([^"]+)"\s*\)/)
        // A bare-string entry stands at the head of the list or straight after
        // a comma, which is what separates it from the quoted argument of a
        // `.product(...)` entry.
        let targets = entries.matches(of: /(?:^|,)\s*"([^"]+)"/)
        return TargetDependencies(
            targetNames: targets.map { String($0.1) },
            productNames: products.map { String($0.1) },
            packageNames: products.map { String($0.2) }
        )
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
