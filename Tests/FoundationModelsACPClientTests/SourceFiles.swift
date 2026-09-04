import Foundation

// The source-file walker of the unit suite. It is an extension of
// `RepositoryFile` rather than a namespace of its own, so the repository-root
// navigation and the `..` path guard stay in one place. `RepositoryFile.read`
// answers for one file; this walker answers for a whole directory tree, which
// is what a test that scans a target needs.
extension RepositoryFile {
    /// Returns the URL of each Swift file below one directory of this
    /// repository.
    ///
    /// The walk is recursive, so a directory a new target adds enters every
    /// caller's scan with no edit here.
    ///
    /// - Parameter relativePath: the directory's path from the repository
    ///   root, for example `"Sources"`.
    /// - Returns: the URL of each file below that directory whose path
    ///   extension is `swift`.
    /// - Throws: `SourceFilesError.directoryUnreadable` when the directory
    ///   cannot be enumerated, or `RepositoryFileError.pathEscapesRepository`
    ///   when the path leaves the repository.
    static func swiftSourceFiles(under relativePath: String) throws -> [URL] {
        let directory = try url(relativePath: relativePath)
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else {
            throw SourceFilesError.directoryUnreadable(relativePath)
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}

/// The failure that `RepositoryFile.swiftSourceFiles(under:)` throws when it
/// cannot walk the directory it was given.
enum SourceFilesError: Error, CustomStringConvertible {
    /// The walk cannot enumerate the directory at this repository-relative
    /// path.
    case directoryUnreadable(String)

    var description: String {
        switch self {
        case .directoryUnreadable(let relativePath):
            return "The scan cannot enumerate \"\(relativePath)\" below the repository root."
        }
    }
}
