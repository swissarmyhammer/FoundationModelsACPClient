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
/// future breaking minor. This suite reads the manifest as text and pins
/// exactly those.
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

    /// The index of the one capture group of the target-block pattern, which
    /// holds the text of the `dependencies:` array.
    private static let dependencyListCapture = 1

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

    @Test("the client target links the wire, the parser, the terminal package and the family leaf")
    func theTargetLinksEveryProductTheBinaryNeeds() throws {
        // The library target alone, and not a union with the executable:
        // cli-plan.md §3 gives every one of these links to AcpClientCore, so
        // moving one down to the executable must fail this rule.
        let dependencies = try Self.clientTargetDependencies()
        #expect(
            Self.requiredProductNames.isSubset(of: Set(dependencies.productNames)),
            """
            The \(Self.clientTargetName) target must name each of \
            \(Self.requiredProductNames.sorted()) as a product dependency. \
            It names \(dependencies.productNames.sorted()).
            """
        )
    }

    @Test("the client target declares exactly the five dependencies section 12 permits")
    func theTargetDeclaresFiveDependencies() throws {
        // The library target alone. The cap counts where the dependencies
        // stand, and `theExecutableTargetTakesTheLibraryAlone` is what stops a
        // sixth one hiding in the executable instead.
        let dependencies = try Self.clientTargetDependencies()
        #expect(
            dependencies.targetNames == ["FoundationModelsACPClient"],
            """
            The \(Self.clientTargetName) target must take this package's own \
            library target, and no other target. \
            It takes \(dependencies.targetNames).
            """
        )
        #expect(
            dependencies.targetNames.count + dependencies.productNames.count
                == Self.permittedDependencyCount,
            """
            cli-plan.md section 12 permits the command-line client five \
            dependencies. \(Self.clientTargetName) declares \
            \(dependencies.targetNames) and \(dependencies.productNames).
            """
        )
    }

    @Test("the acp-client executable target takes the library and nothing else")
    func theExecutableTargetTakesTheLibraryAlone() throws {
        let dependencies = try Self.executableTargetDependencies()
        #expect(
            dependencies.targetNames == [Self.clientTargetName],
            """
            The \(Self.executableTargetName) executable target holds the @main \
            type alone, so cli-plan.md section 3 gives it \
            \(Self.clientTargetName) as its one dependency and no other target. \
            It takes \(dependencies.targetNames).
            """
        )
        #expect(
            dependencies.productNames.isEmpty,
            """
            The \(Self.executableTargetName) executable target must name no \
            package product. Every product the binary needs reaches it through \
            \(Self.clientTargetName), which is where the five that cli-plan.md \
            section 12 permits are counted. It names \
            \(dependencies.productNames.sorted()).
            """
        )
    }

    @Test("neither target of the command-line client names a forbidden module")
    func neitherTargetNamesAForbiddenModule() throws {
        // Both targets. Section 12 bans these modules from the BINARY, and the
        // binary is the library and the executable together, so reading one of
        // them would leave the other free to name one.
        let named = try Self.clientTargetDependencies().allNames
            .union(Self.executableTargetDependencies().allNames)
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

        /// Every name the list holds, whichever form the entry is written in.
        var allNames: Set<String> {
            Set(targetNames + productNames + packageNames)
        }
    }

    /// The dependency entries the ``clientTargetName`` library target declares.
    ///
    /// - Returns: the entries, split by form.
    /// - Throws: an error when the manifest cannot be read, or when it declares
    ///   no such library target.
    private static func clientTargetDependencies() throws -> TargetDependencies {
        try dependencies(ofTargetNamed: clientTargetName, declaredBy: "target")
    }

    /// The dependency entries the ``executableTargetName`` executable target
    /// declares.
    ///
    /// - Returns: the entries, split by form.
    /// - Throws: an error when the manifest cannot be read, or when it declares
    ///   no such executable target.
    private static func executableTargetDependencies() throws -> TargetDependencies {
        try dependencies(ofTargetNamed: executableTargetName, declaredBy: "executableTarget")
    }

    /// Reads `Package.swift` and returns the dependency entries one target
    /// block declares.
    ///
    /// One reader serves both targets of the command-line client, so a rule
    /// that must hold on each of them is written once and cannot read one side
    /// only.
    ///
    /// - Parameters:
    ///   - name: the target name the block declares.
    ///   - declaration: the manifest function that declares it, without its
    ///     leading dot — `target` or `executableTarget`.
    /// - Returns: the entries of that block, split by form.
    /// - Throws: an error when the manifest cannot be read, or when it declares
    ///   no such target block.
    private static func dependencies(
        ofTargetNamed name: String,
        declaredBy declaration: String
    ) throws -> TargetDependencies {
        let manifest = try RepositoryFile.read(relativePath: "Package.swift")
        // The dependency array holds no `]` of its own, so everything up to the
        // first closing bracket is the whole list. `\.target\(` cannot match
        // `.executableTarget(`, because that name carries no dot before its
        // capital `T`, so the two blocks never read each other.
        //
        // `Regex` is not `Sendable`, so the pattern is built here rather than
        // stored, matching how `theNooraRequirementIsUpToNextMinor` writes its
        // own.
        let block = try Regex(
            #"\.\#(declaration)\(\s*name:\s*"\#(name)",\s*dependencies:\s*\[([^\]]*)\]"#
        )
        let match = try #require(
            manifest.firstMatch(of: block),
            """
            Package.swift must declare \
            `.\(declaration)(name: "\(name)", dependencies: [...])`.
            """
        )
        let entries = try #require(
            match.output[dependencyListCapture].substring,
            "The dependency list of the \(name) target did not capture."
        )
        return dependencies(inList: String(entries))
    }

    /// Splits one dependency list into the entries it holds, by the form the
    /// manifest writes each one in.
    ///
    /// - Parameter list: the text between the brackets of a `dependencies:`
    ///   array.
    /// - Returns: the entries, split by form.
    private static func dependencies(inList list: String) -> TargetDependencies {
        let products = list.matches(of: /\.product\(\s*name:\s*"([^"]+)",\s*package:\s*"([^"]+)"\s*\)/)
        // A bare-string entry stands at the head of the list or straight after
        // a comma, which is what separates it from the quoted argument of a
        // `.product(...)` entry.
        let targets = list.matches(of: /(?:^|,)\s*"([^"]+)"/)
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
