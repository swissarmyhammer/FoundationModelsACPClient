import Foundation

/// Reads parts of Swift source text for the tests that check the shape of a
/// source file.
///
/// Some rules cannot be seen from a behavior test: a handler that must hold
/// one statement, or an entry point that must call one function first. The
/// tests of those rules read the source, and these are the readers they share.
enum SwiftSourceText {
    /// The text that opens a line comment.
    private static let lineCommentOpening = "//"

    /// The character that opens a block.
    private static let blockOpening: Character = "{"

    /// The character that closes a block.
    private static let blockClosing: Character = "}"

    /// Returns the text between the brace at the end of `opening` and the
    /// brace that closes it, or `nil` when the source holds no such block.
    ///
    /// The scan counts braces from the opening one, so a nested block inside
    /// the body stays inside the body.
    ///
    /// - Parameters:
    ///   - opening: The text that opens the block. It must end with `{`.
    ///   - source: The whole text of the file.
    /// - Returns: The body, without its own braces.
    static func body(openedBy opening: String, in source: String) -> String? {
        guard let start = source.range(of: opening) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex {
            depth += depthChange(at: source[index])
            if depth == 0 {
                return String(source[start.upperBound..<index])
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Returns the lines of `body` that hold a statement: not blank, and not a
    /// line comment.
    ///
    /// - Parameter body: The body to read.
    /// - Returns: Each statement line, trimmed.
    static func statementLines(of body: String) -> [String] {
        body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(lineCommentOpening) }
    }

    /// Returns how one character changes the block depth.
    ///
    /// - Parameter character: The character to read.
    /// - Returns: `1` for an opening brace, `-1` for a closing brace, and `0`
    ///   for each other character.
    private static func depthChange(at character: Character) -> Int {
        switch character {
        case blockOpening: 1
        case blockClosing: -1
        default: 0
        }
    }
}
