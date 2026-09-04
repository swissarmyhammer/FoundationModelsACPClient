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

    @Test("the reader reads every form SwiftPM accepts for a dependency entry")
    func theReaderReadsEveryDependencyForm() throws {
        // Every rule above stands on this reader, so a form the reader cannot
        // see is a form no rule holds against. The manifest itself writes two
        // of the forms, so the other three are pinned here instead.
        let manifest = """
            .executableTarget(
                name: "probe",
                dependencies: [
                    "BareString",
                    .byName(name: "ByName"),
                    .target(name: "Target"),
                    .product(name: "Product", package: "ProductPackage"),
                    .product(
                        name: "Conditional",
                        package: "ConditionalPackage",
                        condition: .when(platforms: [.macOS])
                    ),
                    // The comment names "AfterTheCondition" and splits nothing.
                    "AfterTheCondition",
                ]
            ),
            """
        let dependencies = try Self.probeDependencies(in: manifest)
        #expect(
            dependencies.targetNames
                == ["BareString", "ByName", "Target", "AfterTheCondition"],
            """
            A bare string literal, `.byName(name:)` and `.target(name:)` each \
            name a module directly, and the entry after a bracket-carrying one \
            still stands in the list. The reader read \
            \(dependencies.targetNames).
            """
        )
        #expect(
            dependencies.productNames == ["Product", "Conditional"],
            """
            A `.product(...)` entry reads whatever trailing `condition:` \
            argument follows the package. The reader read \
            \(dependencies.productNames).
            """
        )
        #expect(
            dependencies.packageNames == ["ProductPackage", "ConditionalPackage"],
            "The reader read the packages \(dependencies.packageNames)."
        )
        #expect(
            dependencies.unreadableEntries.isEmpty,
            "The reader could not read \(dependencies.unreadableEntries)."
        )
    }

    @Test("the reader reports an entry no form reads, and drops none")
    func theReaderReportsAnEntryNoFormReads() throws {
        // A dropped entry would be an invisible dependency, so the reader
        // reports what it cannot read and `dependencies(ofTargetNamed:
        // declaredBy:)` fails on it.
        let manifest = """
            .target(
                name: "probe",
                dependencies: [
                    "Named",
                    dependencyHeldInAConstant,
                ]
            ),
            """
        let dependencies = try Self.probeDependencies(
            in: manifest,
            declaredBy: "target"
        )
        #expect(
            dependencies.unreadableEntries == ["dependencyHeldInAConstant"],
            """
            An entry in no form the reader knows must be reported, so that a \
            rule cannot pass over it. The reader reported \
            \(dependencies.unreadableEntries).
            """
        )
        #expect(
            dependencies.targetNames == ["Named"],
            """
            An unreadable entry must not take the entries beside it out of the \
            list. The reader read \(dependencies.targetNames).
            """
        )
    }

    /// Reads the dependency entries of the `probe` target of a manifest written
    /// for one test.
    ///
    /// - Parameters:
    ///   - manifest: the manifest text to read.
    ///   - declaration: the manifest function that declares the target, without
    ///     its leading dot.
    /// - Returns: the entries, split by form.
    /// - Throws: an error when the text declares no such target block.
    private static func probeDependencies(
        in manifest: String,
        declaredBy declaration: String = "executableTarget"
    ) throws -> TargetDependencies {
        let entries = try dependencyEntries(
            ofTargetNamed: "probe",
            declaredBy: declaration,
            in: manifest
        )
        return dependencies(inEntries: entries)
    }

    /// The dependency entries one target of the manifest declares, split by the
    /// form the manifest writes each one in.
    private struct TargetDependencies {
        /// The name in each entry that names a module directly: a bare string
        /// literal, `.byName(name:)`, or `.target(name:)`.
        let targetNames: [String]

        /// The product name in each `.product(...)` entry, whatever trailing
        /// `moduleAliases:` or `condition:` argument follows it.
        let productNames: [String]

        /// The package name in each `.product(...)` entry that names one.
        let packageNames: [String]

        /// The text of each entry no form this reader knows can read.
        ///
        /// A reader that dropped an entry it did not recognise would be blind
        /// to that form, and every rule that reads a dependency list would be
        /// evadable by writing one entry in it.
        /// ``dependencies(ofTargetNamed:declaredBy:)`` fails on this instead,
        /// so an unread entry stops the suite rather than passing it.
        let unreadableEntries: [String]

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
    /// The manifest is read as text, and not through `swift package
    /// dump-package`, which would give every entry in one normal form. That
    /// command cannot run from inside this suite: SwiftPM holds a lock on
    /// `.build` for the whole of a `swift test` run, so the child waits for the
    /// parent, and the parent waits for the child. Measured on 2026-09-04, a
    /// `dump-package` call from inside a test of this package printed `Another
    /// instance of SwiftPM (PID: 4712) is already running using '.build',
    /// waiting until that process has finished execution...`, gave no output,
    /// and was killed at 45 seconds. So this reader reads the text, and reads
    /// every entry form SwiftPM accepts.
    ///
    /// - Parameters:
    ///   - name: the target name the block declares.
    ///   - declaration: the manifest function that declares it, without its
    ///     leading dot — `target` or `executableTarget`.
    /// - Returns: the entries of that block, split by form.
    /// - Throws: an error when the manifest cannot be read, when it declares no
    ///   such target block, or when that block holds an entry in a form this
    ///   reader does not know.
    private static func dependencies(
        ofTargetNamed name: String,
        declaredBy declaration: String
    ) throws -> TargetDependencies {
        let manifest = try RepositoryFile.read(relativePath: "Package.swift")
        let entries = try dependencyEntries(
            ofTargetNamed: name,
            declaredBy: declaration,
            in: manifest
        )
        let declared = dependencies(inEntries: entries)
        try #require(
            declared.unreadableEntries.isEmpty,
            """
            No form this reader knows reads \(declared.unreadableEntries) of \
            the \(name) target. Teach `dependencies(inEntries:)` that form \
            rather than leave it out: a rule cannot hold against an entry the \
            reader cannot see.
            """
        )
        return declared
    }

    /// Reads the text of each entry of the `dependencies:` array of one target
    /// block.
    ///
    /// - Parameters:
    ///   - name: the target name the block declares.
    ///   - declaration: the manifest function that declares it, without its
    ///     leading dot — `target` or `executableTarget`.
    ///   - manifest: the text of `Package.swift`.
    /// - Returns: the text of each entry, in the order the array writes them.
    /// - Throws: an error when the manifest declares no such target block.
    private static func dependencyEntries(
        ofTargetNamed name: String,
        declaredBy declaration: String,
        in manifest: String
    ) throws -> [String] {
        // `\.target\(` cannot match `.executableTarget(`, because that name
        // carries no dot before its capital `T`, so the two blocks never read
        // each other.
        //
        // `Regex` is not `Sendable`, so the pattern is built here rather than
        // stored, matching how `theNooraRequirementIsUpToNextMinor` writes its
        // own.
        let header = try Regex(
            #"\.\#(declaration)\(\s*name:\s*"\#(name)"\s*,\s*dependencies:\s*\["#
        )
        let match = try #require(
            manifest.firstMatch(of: header),
            """
            Package.swift must declare \
            `.\(declaration)(name: "\(name)", dependencies: [...])`.
            """
        )
        return entries(ofArrayAfter: match.range.upperBound, in: manifest)
    }

    /// Splits the `dependencies:` array whose opening bracket ends at `start`
    /// into the entries it holds.
    ///
    /// The array is read by nesting depth, and not by a pattern that stops at
    /// the first `]`. An entry may carry brackets of its own — `condition:
    /// .when(platforms: [.macOS])` is one — and a pattern that stopped there
    /// would drop every entry that stands after such an entry. Text inside a
    /// string literal and text after `//` change no depth, so a bracket or a
    /// comma written in either one splits nothing.
    ///
    /// - Parameters:
    ///   - start: the index of the first character after the opening `[`.
    ///   - manifest: the text of `Package.swift`.
    /// - Returns: the trimmed text of each entry, in the order the array writes
    ///   them.
    private static func entries(
        ofArrayAfter start: String.Index,
        in manifest: String
    ) -> [String] {
        let characters = Array(manifest[start...])
        var entries: [String] = []
        var entry = ""
        var depth = 0
        var isInStringLiteral = false
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            index += 1
            if isInStringLiteral {
                entry.append(character)
                if character == #"\"#, index < characters.endIndex {
                    entry.append(characters[index])
                    index += 1
                } else if character == "\"" {
                    isInStringLiteral = false
                }
                continue
            }
            if character == "/", index < characters.endIndex, characters[index] == "/" {
                while index < characters.endIndex, characters[index] != "\n" {
                    index += 1
                }
                continue
            }
            if depth == 0, character == "]" {
                break
            }
            if depth == 0, character == "," {
                entries.append(entry)
                entry = ""
                continue
            }
            if character == "[" || character == "(" {
                depth += 1
            }
            if character == "]" || character == ")" {
                depth -= 1
            }
            if character == "\"" {
                isInStringLiteral = true
            }
            entry.append(character)
        }
        entries.append(entry)
        return entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// One entry of a `dependencies:` array, read into the form it is written
    /// in.
    ///
    /// SwiftPM accepts a `Target.Dependency` as a bare string literal, as
    /// `.byName(name:)`, as `.target(name:)`, and as `.product(name:package:)`,
    /// the last three with or without a trailing `moduleAliases:` or
    /// `condition:` argument. The first three name a module directly, so they
    /// fold into one case here: every rule of this suite reads the name, and
    /// none of them reads the spelling.
    private enum DependencyEntry {
        /// An entry that names a module directly, by that name.
        case module(String)

        /// A `.product(...)` entry, by its product name and by the package it
        /// names, where it names one.
        case product(name: String, package: String?)

        /// An entry no form this reader knows can read, by its text.
        case unreadable(String)

        /// The module this entry names directly, or `nil` in every other form.
        var moduleName: String? {
            switch self {
            case .module(let name): name
            case .product, .unreadable: nil
            }
        }

        /// The product this entry names, or `nil` in every other form.
        var productName: String? {
            switch self {
            case .product(let name, _): name
            case .module, .unreadable: nil
            }
        }

        /// The package this entry names, or `nil` where it names none.
        var packageName: String? {
            switch self {
            case .product(_, let package): package
            case .module, .unreadable: nil
            }
        }

        /// The text of this entry where no known form reads it, or `nil` where
        /// one does.
        var unreadableText: String? {
            switch self {
            case .unreadable(let text): text
            case .module, .product: nil
            }
        }
    }

    /// Splits the entries of one dependency list by the form each is written
    /// in.
    ///
    /// - Parameter entries: the text of each entry of a `dependencies:` array.
    /// - Returns: the entries, split by form.
    private static func dependencies(inEntries entries: [String]) -> TargetDependencies {
        let read = entries.map { dependencyEntry(readFrom: $0) }
        return TargetDependencies(
            targetNames: read.compactMap(\.moduleName),
            productNames: read.compactMap(\.productName),
            packageNames: read.compactMap(\.packageName),
            unreadableEntries: read.compactMap(\.unreadableText)
        )
    }

    /// Reads one entry of a dependency list into the form it is written in.
    ///
    /// Every form SwiftPM accepts names a module the binary links, so this
    /// reader reads them all: a form it cannot read is a form no rule can hold
    /// against, and a person could write the dependency that way and pass. An
    /// entry in a form it does not know comes back as
    /// ``DependencyEntry/unreadable(_:)``, never dropped.
    ///
    /// - Parameter text: the text of one entry.
    /// - Returns: that entry, in the form it is written in.
    private static func dependencyEntry(readFrom text: String) -> DependencyEntry {
        // `Regex` is not `Sendable`, so the patterns are local rather than
        // stored constants, matching how `theNooraRequirementIsUpToNextMinor`
        // writes its own.
        let quotedLiteral = /"([^"]+)"/
        let quotedName = /name:\s*"([^"]+)"/
        let quotedPackage = /package:\s*"([^"]+)"/
        // A bare string literal carries the name on its own; every other form
        // carries it as the `name:` argument.
        let namePattern = text.hasPrefix("\"") ? quotedLiteral : quotedName
        let name = text.firstMatch(of: namePattern).map { String($0.1) }
        let package = text.firstMatch(of: quotedPackage).map { String($0.1) }
        if let name, text.contains(".product") {
            return .product(name: name, package: package)
        }
        if let name {
            return .module(name)
        }
        return .unreadable(text)
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
