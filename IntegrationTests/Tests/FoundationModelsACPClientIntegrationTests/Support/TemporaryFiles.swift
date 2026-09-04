import Foundation

// The one temporary-file naming and writing the support files of this suite
// share.
//
// Several helpers here hand a process a file rather than a pipe: a stub agent
// gets its behaviour as a `/bin/sh` script, and a bounded `acp-client` run gets
// its standard input as a regular file. Each such file wants the same three
// things — the temporary directory, a name no concurrent test can collide with,
// and one atomic write — so the three live here once and the callers name only
// what differs.
//
// A stub agent also writes files of its own, which this process never writes at
// all: the agent's pid, and the request lines it read. Those need the first two
// things and not the third, so the naming stands on its own beside the write.

/// Writes `content` into a fresh file in the temporary directory.
///
/// The file is written atomically, so a reader never sees a half-written file.
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
    let file = temporaryFileURL(prefix: prefix, suffix: suffix)
    try content.write(to: file, options: .atomic)
    return file
}

/// Names a fresh file in the temporary directory, and writes nothing there.
///
/// The name carries a UUID, so two tests that run at one time never name the
/// same path.
///
/// A stub agent writes some of its files itself — its own pid, the request
/// lines it read — so the test that spawns it needs the PATH before any file
/// stands at it. That is what this gives, and ``writeTemporaryFile(_:prefix:suffix:)``
/// is the same naming with one write after it.
///
/// - Parameters:
///   - prefix: The text that stands before the unique part of the name. It says
///     which helper named the file, which is what makes a leftover file
///     traceable.
///   - suffix: The text that stands after the unique part of the name, an
///     extension included, or the empty string for a file that needs none.
/// - Returns: The file URL; nothing stands at it yet, and the caller removes
///   whatever comes to.
func temporaryFileURL(prefix: String, suffix: String = "") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
}
