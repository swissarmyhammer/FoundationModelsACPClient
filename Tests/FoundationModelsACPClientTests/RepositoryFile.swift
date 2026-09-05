import Foundation

/// Reads files that live in this repository, found relative to this source
/// file through `#filePath`.
///
/// `#filePath` resolves relative to the file that contains the literal, so
/// the navigation in `rootURL` starts at this helper's own location:
/// `Tests/FoundationModelsACPClientTests/RepositoryFile.swift`.
/// Three `deletingLastPathComponent()` steps go from this file to the
/// repository root. Keep this file directly inside
/// `Tests/FoundationModelsACPClientTests/`, or adjust the step count to
/// match the new location.
enum RepositoryFile {
    /// The URL of this repository's root directory.
    static let rootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // RepositoryFile.swift → FoundationModelsACPClientTests/
        .deletingLastPathComponent()  // → Tests/
        .deletingLastPathComponent()  // → repository root

    /// Locates one file or directory of this repository.
    ///
    /// - Parameter relativePath: the item's path from the repository root,
    ///   for example `".github/workflows/ci.yml"` or `"Sources"`.
    /// - Returns: the URL of that item, whether or not it exists.
    /// - Throws: `RepositoryFileError.pathEscapesRepository` when the path
    ///   contains `..` or starts with `/`.
    static func url(relativePath: String) throws -> URL {
        // Reject a path with ".." or a leading "/", because such a path can
        // point to a file outside the repository.
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else {
            throw RepositoryFileError.pathEscapesRepository(relativePath)
        }
        return rootURL.appendingPathComponent(relativePath)
    }

    /// Returns the path of one item of this repository, from the repository
    /// root.
    ///
    /// This is the inverse of `url(relativePath:)`. A test that walks a
    /// directory holds absolute URLs, and a document names a repository-
    /// relative path, so one of the two must convert before they compare.
    ///
    /// - Parameter url: the URL of a file or a directory.
    /// - Returns: that item's path from the repository root, or `nil` when
    ///   the item stands outside this repository.
    static func relativePath(of url: URL) -> String? {
        let root = rootURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let item = url.standardizedFileURL.path
        guard item.hasPrefix(prefix) else {
            return nil
        }
        return String(item.dropFirst(prefix.count))
    }

    /// Reads one repository file as UTF-8 text.
    ///
    /// - Parameter relativePath: the file's path from the repository root,
    ///   for example `".github/workflows/ci.yml"` or `"README.md"`.
    /// - Returns: the file's full text.
    /// - Throws: `RepositoryFileError.pathEscapesRepository` when the path
    ///   contains `..` or starts with `/`, or an error when the file cannot
    ///   be read.
    static func read(relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath: relativePath), encoding: .utf8)
    }
}

/// The failure that `RepositoryFile.url(relativePath:)` throws when the
/// given path is not safe.
enum RepositoryFileError: Error, CustomStringConvertible {
    /// The path contains `..` or starts with `/`, so it can point to a file
    /// outside the repository.
    case pathEscapesRepository(String)

    var description: String {
        switch self {
        case .pathEscapesRepository(let relativePath):
            return "relativePath \"\(relativePath)\" must stay inside the repository: "
                + "it must not contain \"..\" and must not start with \"/\"."
        }
    }
}
