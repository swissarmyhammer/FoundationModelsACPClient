import Foundation

// The one temporary-file writer the support files of this suite share.
//
// Several helpers here hand a process a file rather than a pipe: a stub agent
// gets its behaviour as a `/bin/sh` script, and a bounded `acp-client` run gets
// its standard input as a regular file. Each such file wants the same three
// things — the temporary directory, a name no concurrent test can collide with,
// and one atomic write — so the three live here once and the callers name only
// what differs.

/// Writes `content` into a fresh file in the temporary directory.
///
/// The name carries a UUID, so two tests that run at one time never write the
/// same path, and the file is written atomically, so a reader never sees a
/// half-written file.
///
/// - Parameters:
///   - content: The bytes to write.
///   - prefix: The text that stands before the unique part of the name. It says
///     which helper wrote the file, which is what makes a leftover file
///     traceable.
///   - suffix: The text that stands after the unique part of the name, an
///     extension included, or the empty string for a file that needs none.
/// - Returns: The file URL of the written file; the caller removes it.
/// - Throws: The write failure of the temporary file.
func writeTemporaryFile(_ content: Data, prefix: String, suffix: String = "") throws -> URL {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    try content.write(to: file, options: .atomic)
    return file
}
