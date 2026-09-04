// `AgentCommandResolver` — the one place the binary turns the agent command of
// `cli-plan.md` §6 into an absolute path.
//
// The library refuses to do this on purpose. `AgentProcess.init(command:)`
// throws `AgentProcessError.commandNotAbsolute` for any command that does not
// start with `/`, because a `PATH` lookup would have to select *which* `PATH`
// applies, and a library cannot answer that. A binary can: its `PATH` is the
// one its user typed the command into. So the lookup lives here, and every
// value `resolve(_:)` returns is a value `AgentProcess` accepts.
//
// §6 needs it. `acp-client probe -- npx @vendor/agent` names `npx`, a bare
// name, and the first check of the `doctor` table in §10 — "the command exists
// on `PATH`, or at the given path, and it is executable" — reports the outcome
// of exactly this resolution. `run`, `probe` and `doctor` share the one
// resolver rather than each growing a lookup of its own.

import Foundation

/// A failure while resolving the agent command to an absolute executable path.
///
/// Every case carries the path or the name that failed, because the person
/// reading the message has to know which command to correct.
enum AgentCommandResolutionFailure: Error, Equatable, CustomStringConvertible {
    /// A bare command name matched no executable in any `PATH` directory.
    ///
    /// The searched directories travel with the failure so that the message
    /// can name where the binary looked, which is what separates "you spelled
    /// it wrong" from "your `PATH` does not hold it".
    case notFoundOnPath(String, searchedDirectories: [String])

    /// The command named a path, and nothing exists there.
    case noSuchFile(String)

    /// The command named a file that exists and carries no executable bit.
    case notExecutable(String)

    /// The command named something that is not a regular file, such as a
    /// directory.
    case notARegularFile(String)

    /// A human-readable description of this error.
    var description: String {
        switch self {
        case .notFoundOnPath(let command, let searchedDirectories):
            return """
                No executable named "\(command)" was found on PATH. \
                \(Self.searchedSentence(for: searchedDirectories))
                """
        case .noSuchFile(let path):
            return "No file exists at \"\(path)\"."
        case .notExecutable(let path):
            return """
                The file at "\(path)" is not executable. \
                Give it the executable bit, as in: chmod +x "\(path)"
                """
        case .notARegularFile(let path):
            return "\"\(path)\" is not a regular file, so it cannot be run."
        }
    }

    /// Returns the sentence of ``description`` that names where the search
    /// looked.
    ///
    /// - Parameter searchedDirectories: The directories the search covered, in
    ///   the order it covered them.
    /// - Returns: A sentence naming each directory, or one saying the `PATH`
    ///   was empty, which is a different mistake and needs a different fix.
    private static func searchedSentence(for searchedDirectories: [String]) -> String {
        guard !searchedDirectories.isEmpty else {
            return "PATH is empty, so no directory was searched."
        }
        return "Searched: \(searchedDirectories.joined(separator: ", "))."
    }
}

/// Turns the agent command of `cli-plan.md` §6 into the absolute path
/// ``AgentProcess/init(command:arguments:)`` requires.
///
/// The `PATH` value and the file system both arrive at ``init(path:fileManager:)``
/// rather than being read from the process, so a test drives the search over a
/// temporary directory tree and never over the machine's own `PATH`.
struct AgentCommandResolver: Sendable {
    /// The character that separates one `PATH` entry from the next.
    static let pathEntrySeparator: Character = ":"

    /// The character whose presence makes a command a path rather than a name,
    /// matching the rule every shell uses.
    private static let pathSeparator: Character = "/"

    /// The `PATH` directories, in the order the search takes them.
    ///
    /// Empty entries are dropped. POSIX reads an empty entry as the working
    /// directory, and a working directory on `PATH` is how a command in a
    /// downloaded folder gets run by mistake, so this resolver searches named
    /// directories alone.
    private let searchDirectories: [String]

    /// The file system this resolver asks about each candidate, and the source
    /// of the working directory a relative command resolves against.
    ///
    /// `FileManager` is not `Sendable`, and this value is. The exception is
    /// safe here because the resolver only asks questions: it reads paths, it
    /// changes nothing on the file system, and it never assigns the delegate
    /// that Apple's own documentation names as the one thing making a shared
    /// file manager unsafe.
    nonisolated(unsafe) private let fileManager: FileManager

    /// Creates a resolver over one `PATH` value and one file system.
    ///
    /// - Parameters:
    ///   - path: The `PATH` value to search, entries separated by
    ///     ``pathEntrySeparator``. The default is this process's own `PATH`.
    ///   - fileManager: The file system to ask about each candidate, and to
    ///     ask for the process working directory.
    init(path: String = Self.environmentPath(), fileManager: FileManager = .default) {
        searchDirectories = path
            .split(separator: Self.pathEntrySeparator, omittingEmptySubsequences: true)
            .map(String.init)
        self.fileManager = fileManager
    }

    /// Returns this process's `PATH`.
    ///
    /// - Returns: The `PATH` environment value, or the empty string when the
    ///   environment carries none. An empty value searches no directory, which
    ///   is the honest reading of a `PATH` that is not set.
    static func environmentPath() -> String {
        ProcessInfo.processInfo.environment["PATH"] ?? ""
    }

    /// Resolves one agent command to an absolute executable path.
    ///
    /// A command that holds a `/` is a path, and it is checked where it points
    /// — made absolute against the process working directory first, so that
    /// `./agent` and `agents/mine` both work. A bare name is searched through
    /// ``searchDirectories`` in order, and the first executable regular file
    /// wins.
    ///
    /// - Parameter command: The agent command as the command line gave it.
    /// - Returns: An absolute path, which is what
    ///   ``AgentProcess/init(command:arguments:)`` accepts.
    /// - Throws: ``AgentCommandResolutionFailure``. The type is spelled on the
    ///   signature, and not left to `any Error`, because the first check of
    ///   the `doctor` table of `cli-plan.md` §10 gives each case its own fix
    ///   text: a caller that switches over the cases must be able to switch
    ///   over all of them and no more.
    func resolve(_ command: String) throws(AgentCommandResolutionFailure) -> String {
        guard command.contains(Self.pathSeparator) else {
            return try searchPath(for: command)
        }
        return try resolveGivenPath(command)
    }

    /// Resolves a command that names a path.
    ///
    /// - Parameter command: A command holding at least one ``pathSeparator``.
    /// - Returns: The same place, spelled from the root.
    /// - Throws: ``AgentCommandResolutionFailure/noSuchFile(_:)``,
    ///   ``AgentCommandResolutionFailure/notARegularFile(_:)`` or
    ///   ``AgentCommandResolutionFailure/notExecutable(_:)``.
    private func resolveGivenPath(
        _ command: String
    ) throws(AgentCommandResolutionFailure) -> String {
        let path = absolutePath(for: command)
        if let reason = failure(at: path) { throw reason }
        return path
    }

    /// Searches ``searchDirectories`` in order for an executable of one name.
    ///
    /// - Parameter name: A bare command name, holding no ``pathSeparator``.
    /// - Returns: The absolute path of the first executable regular file of
    ///   that name.
    /// - Throws: ``AgentCommandResolutionFailure/notFoundOnPath(_:searchedDirectories:)``
    ///   when no directory holds one.
    private func searchPath(
        for name: String
    ) throws(AgentCommandResolutionFailure) -> String {
        for directory in searchDirectories {
            let candidate = absolutePath(for: "\(directory)\(Self.pathSeparator)\(name)")
            guard failure(at: candidate) == nil else { continue }
            return candidate
        }
        throw AgentCommandResolutionFailure.notFoundOnPath(
            name, searchedDirectories: searchDirectories
        )
    }

    /// Makes one path absolute against the process working directory.
    ///
    /// - Parameter path: A path, absolute or relative.
    /// - Returns: The same place, spelled from the root. An already absolute
    ///   path keeps its spelling.
    private func absolutePath(for path: String) -> String {
        let workingDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true
        )
        return URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL.path
    }

    /// Returns why `path` cannot be run, or `nil` when it can.
    ///
    /// The three failures are distinct on purpose: a missing file, a file that
    /// is not a file, and a file that carries no executable bit are three
    /// different mistakes with three different fixes.
    ///
    /// - Parameter path: An absolute path.
    /// - Returns: The failure to report, or `nil` when `path` is an executable
    ///   regular file.
    private func failure(at path: String) -> AgentCommandResolutionFailure? {
        // `fileExists(atPath:)` follows symbolic links, so a link that points
        // at nothing is reported as the missing file it is.
        guard fileManager.fileExists(atPath: path) else { return .noSuchFile(path) }
        guard isRegularFile(at: path) else { return .notARegularFile(path) }
        guard fileManager.isExecutableFile(atPath: path) else { return .notExecutable(path) }
        return nil
    }

    /// Answers whether `path` names a regular file.
    ///
    /// The symbolic links are resolved first, because
    /// `attributesOfItem(atPath:)` reports the link itself rather than what it
    /// points at, and a `PATH` directory holding a link to the real binary is
    /// the ordinary case rather than the odd one.
    ///
    /// - Parameter path: An absolute path that exists.
    /// - Returns: `true` for a regular file, and `false` for a directory, a
    ///   named pipe, a socket, a device, or anything else that is not a file
    ///   to run.
    private func isRegularFile(at path: String) -> Bool {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attributes = try? fileManager.attributesOfItem(atPath: target)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }
}
