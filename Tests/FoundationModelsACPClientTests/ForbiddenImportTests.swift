import Foundation
import Testing

/// The module names that the dependency boundary bans from `Sources/`.
///
/// The scan compares the full module name, so `FoundationModels` does not
/// match the permitted `FoundationModelsACP`. `Observation` and `Foundation`
/// stay permitted.
///
/// `ManifestTests` reads the same set from the other side of the boundary: no
/// target block of `Package.swift` may name one of these either. One list, so
/// the two halves of the rule cannot drift apart.
let forbiddenModules: Set<String> = [
    "FoundationModels",
    "FoundationModelsACPAgent",
    "FoundationModelsMCP",
    "FoundationModelsRouter",
    "SwiftUI",
]

/// Returns each forbidden import in one file, as `file: import Module` lines.
private func forbiddenImports(in file: URL) throws -> [String] {
    // Matches an import statement at the start of a line and captures the
    // module name. The pattern accepts the forms Swift permits before the
    // name: attributes such as `@_exported`, an access level such as
    // `public`, and an import kind such as `struct`. The regex is local
    // because `Regex` is not `Sendable`, so it cannot be a global constant.
    let importStatement =
        /^\s*(?:@\w+\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)/
    let content = try String(contentsOf: file, encoding: .utf8)
    var violations: [String] = []
    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let match = line.firstMatch(of: importStatement) else { continue }
        let module = String(match.1)
        if forbiddenModules.contains(module) {
            violations.append("\(file.lastPathComponent): import \(module)")
        }
    }
    return violations
}

/// The dependency-boundary test. The library must know only the ACP wire and
/// Observation, so no file in `Sources/` may import the agent runtime, the
/// `FoundationModels` framework, or SwiftUI.
///
/// The walk is recursive over the whole of `Sources/`, so the scan covers the
/// `acp-client` executable target as well as the library target. The binary
/// keeps the same boundary: `cli-plan.md` §12 gives it the library, the wire,
/// the parser and the terminal package, and nothing more.
@Test func sourcesHoldNoForbiddenImport() throws {
    let files = try RepositoryFile.swiftSourceFiles(under: "Sources")
    try #require(!files.isEmpty, "The scan found no Swift files below Sources/.")
    var violations: [String] = []
    for file in files {
        violations.append(contentsOf: try forbiddenImports(in: file))
    }
    #expect(violations.isEmpty, "Forbidden imports found: \(violations)")
}
