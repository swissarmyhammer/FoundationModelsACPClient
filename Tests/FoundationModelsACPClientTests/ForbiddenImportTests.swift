import Foundation
import Testing

/// The module names that the dependency boundary bans from `Sources/`.
///
/// The scan compares the full module name, so `FoundationModels` does not
/// match the permitted `FoundationModelsACP`. `Observation` and `Foundation`
/// stay permitted.
private let forbiddenModules: Set<String> = [
    "FoundationModels",
    "FoundationModelsACPAgent",
    "FoundationModelsMCP",
    "FoundationModelsRouter",
    "SwiftUI",
]

/// An error from the scan of the `Sources/` directory.
private enum SourceScanError: Error {
    /// The scan cannot enumerate the `Sources/` directory.
    case sourcesUnreadable
}

/// Returns the URL of each Swift file below `Sources/` in this package.
private func swiftSourceFiles() throws -> [URL] {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourcesDirectory = packageRoot.appendingPathComponent("Sources")
    guard
        let enumerator = FileManager.default.enumerator(
            at: sourcesDirectory,
            includingPropertiesForKeys: nil
        )
    else {
        throw SourceScanError.sourcesUnreadable
    }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

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
@Test func sourcesHoldNoForbiddenImport() throws {
    let files = try swiftSourceFiles()
    try #require(!files.isEmpty, "The scan found no Swift files below Sources/.")
    var violations: [String] = []
    for file in files {
        violations.append(contentsOf: try forbiddenImports(in: file))
    }
    #expect(violations.isEmpty, "Forbidden imports found: \(violations)")
}
