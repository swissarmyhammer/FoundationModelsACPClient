import Foundation

// The import reader the boundary tests share. Two tests ask what a Swift file
// imports, and they ask for opposite reasons: `ForbiddenImportTests` wants the
// modules no file may name, and `TerminalOutputTests` wants the one file that
// may name Noora. One reader answers both, so the two tests cannot disagree
// about what an import statement looks like.

/// Reads the import statements of a Swift source file.
enum SwiftImports {
    /// Returns the module of each import statement in one Swift file, in the
    /// order the file gives them.
    ///
    /// A module named more than once appears more than once, because the
    /// reader reports statements and does not fold them together.
    ///
    /// - Parameter file: The Swift file to read.
    /// - Returns: The imported module names, one per import statement.
    /// - Throws: Whatever reading the file throws.
    static func modules(in file: URL) throws -> [String] {
        // Matches an import statement at the start of a line and captures the
        // module name. The pattern accepts the forms Swift permits before the
        // name: attributes such as `@_exported`, an access level such as
        // `public`, and an import kind such as `struct`. The regex is local
        // because `Regex` is not `Sendable`, so it cannot be a global constant.
        let importStatement =
            /^\s*(?:@\w+\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)/
        let content = try String(contentsOf: file, encoding: .utf8)
        return content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line in
                line.firstMatch(of: importStatement).map { String($0.1) }
            }
    }
}
