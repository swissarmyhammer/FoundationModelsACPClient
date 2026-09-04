import Foundation
import Testing

@testable import acp_client

// These tests cover `AgentCommandResolver`, the one place the binary turns the
// agent command of `cli-plan.md` §6 into the absolute path
// `AgentProcess.init(command:arguments:)` requires.
//
// No test reads the machine's own `PATH`, and no test reads the machine's own
// working directory. Each one builds a temporary directory tree, writes files
// into it with chosen permission bits, and hands the resolver a `PATH` made of
// those directories alone. A test that read the real `PATH` would pass or fail
// with whatever the machine happens to have installed, which is not a test.
//
// No test spawns a process either. The suite that spawns a real agent over
// stdio lives in the nested `IntegrationTests` package, and the row that ties
// this resolver to `AgentProcess` is asserted on the shape of the returned
// path — see ``AgentCommandResolverTests/expectAgentProcessAccepts(_:)``.

/// A directory below the system temporary directory, removed when this value
/// is released.
///
/// Swift Testing builds a fresh suite instance for each test, so a suite that
/// holds one of these gets a tree of its own and drops it when the test ends.
/// That is why the cleanup is a `deinit` rather than a `defer` repeated in
/// every test body.
private final class TemporaryDirectory: Sendable {
    /// The absolute path of the directory.
    let path: String

    /// Creates the directory.
    ///
    /// - Throws: Whatever `FileManager.createDirectory` throws.
    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-client-resolver-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Removes the directory and everything below it.
    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A `FileManager` that reports a chosen directory as the process working
/// directory, and answers every other question from the real file system.
///
/// The working directory belongs to the process, so a test that changed the
/// real one would change it for every test running beside it. Overriding the
/// single reading the resolver makes is what keeps the relative-path row
/// testable without that global write.
private final class WorkingDirectoryFileManager: FileManager {
    /// The directory this file manager reports as the working directory.
    private let workingDirectory: String

    /// Creates a file manager that reports `workingDirectory`.
    ///
    /// - Parameter workingDirectory: The absolute path to report.
    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        super.init()
    }

    override var currentDirectoryPath: String { workingDirectory }
}

@Suite("acp-client agent command resolution")
struct AgentCommandResolverTests {
    /// The permission bits of a file its owner may read and run.
    private static let executablePermissions = 0o755

    /// The permission bits of a file its owner may read but not run.
    private static let nonExecutablePermissions = 0o644

    /// The bare command name every test resolves, chosen so that a match can
    /// only come from the temporary tree and never from the real `PATH`.
    private static let agentName = "acp-client-test-agent"

    /// The temporary tree of the running test.
    private let tree: TemporaryDirectory

    /// Builds the temporary tree of one test.
    ///
    /// - Throws: Whatever ``TemporaryDirectory/init()`` throws.
    init() throws {
        tree = try TemporaryDirectory()
    }

    // MARK: - Tree building

    /// Creates a directory below the temporary tree.
    ///
    /// - Parameter name: The name of the directory.
    /// - Returns: The absolute path of the new directory.
    /// - Throws: Whatever `FileManager.createDirectory` throws.
    private func makeDirectory(named name: String) throws -> String {
        let path = URL(fileURLWithPath: tree.path).appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Writes a file with chosen permission bits.
    ///
    /// - Parameters:
    ///   - name: The name of the file.
    ///   - directory: The absolute path of the directory to write it into.
    ///   - permissions: The POSIX permission bits to give the file.
    /// - Returns: The absolute path of the new file.
    /// - Throws: Nothing; a failed write is reported as a test failure.
    @discardableResult
    private func makeFile(
        named name: String,
        in directory: String,
        permissions: Int
    ) throws -> String {
        let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        let created = FileManager.default.createFile(
            atPath: path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: permissions]
        )
        try #require(created, "The test could not write \(path).")
        return path
    }

    /// Builds the value under test over a `PATH` made of the given
    /// directories, with the temporary tree as the working directory.
    ///
    /// - Parameter directories: The `PATH` entries, in search order.
    /// - Returns: A resolver that reads neither the real `PATH` nor the real
    ///   working directory.
    private func resolver(searching directories: [String]) -> AgentCommandResolver {
        AgentCommandResolver(
            path: directories.joined(separator: String(AgentCommandResolver.pathEntrySeparator)),
            fileManager: WorkingDirectoryFileManager(workingDirectory: tree.path)
        )
    }

    /// Asserts that `path` is a value `AgentProcess.init(command:arguments:)`
    /// accepts.
    ///
    /// That initializer refuses any command that does not start with `/`, with
    /// `AgentProcessError.commandNotAbsolute`, and it applies no other test to
    /// the spelling of the command. So an absolute path is the whole of what
    /// it accepts, and the assertion is on the shape rather than on a
    /// construction, because constructing one spawns a process and this
    /// package keeps every spawning test in the nested `IntegrationTests`
    /// package.
    ///
    /// - Parameter path: The value the resolver returned.
    private func expectAgentProcessAccepts(
        _ path: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            path.hasPrefix("/"),
            "AgentProcess would refuse \"\(path)\" as not absolute.",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - The acceptance rows

    /// A bare name resolves to the first executable match in `PATH` order.
    @Test("a bare name resolves to an executable on PATH")
    func aBareNameResolvesToAnExecutableOnPath() throws {
        let directory = try makeDirectory(named: "bin")
        let executable = try makeFile(
            named: Self.agentName, in: directory, permissions: Self.executablePermissions
        )

        #expect(try resolver(searching: [directory]).resolve(Self.agentName) == executable)
    }

    /// The search takes `PATH` in order: two directories hold a file of the
    /// same name, and the earlier entry wins.
    @Test("a bare name takes the earlier PATH entry")
    func aBareNameTakesTheEarlierPathEntry() throws {
        let earlier = try makeDirectory(named: "earlier")
        let later = try makeDirectory(named: "later")
        let winner = try makeFile(
            named: Self.agentName, in: earlier, permissions: Self.executablePermissions
        )
        try makeFile(named: Self.agentName, in: later, permissions: Self.executablePermissions)

        #expect(try resolver(searching: [earlier, later]).resolve(Self.agentName) == winner)
    }

    /// The search takes the first **executable** match, so a match that
    /// carries no executable bit does not end it.
    @Test("a bare name passes over a match that is not executable")
    func aBareNamePassesOverAMatchThatIsNotExecutable() throws {
        let earlier = try makeDirectory(named: "earlier")
        let later = try makeDirectory(named: "later")
        try makeFile(named: Self.agentName, in: earlier, permissions: Self.nonExecutablePermissions)
        let winner = try makeFile(
            named: Self.agentName, in: later, permissions: Self.executablePermissions
        )

        #expect(try resolver(searching: [earlier, later]).resolve(Self.agentName) == winner)
    }

    /// A bare name with no match names every directory that was searched, so
    /// the person reading the error can see where the binary looked.
    @Test("a bare name with no match names every directory searched")
    func aBareNameWithNoMatchNamesEveryDirectorySearched() throws {
        let first = try makeDirectory(named: "first")
        let second = try makeDirectory(named: "second")

        #expect(
            throws: AgentCommandResolutionFailure.notFoundOnPath(
                Self.agentName, searchedDirectories: [first, second]
            )
        ) {
            _ = try resolver(searching: [first, second]).resolve(Self.agentName)
        }
    }

    /// An empty `PATH` searches nothing, and says so.
    @Test("an empty PATH searches no directory")
    func anEmptyPathSearchesNoDirectory() throws {
        #expect(
            throws: AgentCommandResolutionFailure.notFoundOnPath(
                Self.agentName, searchedDirectories: []
            )
        ) {
            _ = try resolver(searching: []).resolve(Self.agentName)
        }
    }

    /// A relative path resolves against the process working directory, and the
    /// result is absolute.
    @Test("a relative path resolves against the working directory")
    func aRelativePathResolvesAgainstTheWorkingDirectory() throws {
        let executable = try makeFile(
            named: Self.agentName, in: tree.path, permissions: Self.executablePermissions
        )

        let resolved = try resolver(searching: []).resolve("./\(Self.agentName)")

        #expect(resolved == executable)
        expectAgentProcessAccepts(resolved)
    }

    /// An absolute path that is an executable regular file comes back
    /// unchanged.
    @Test("an absolute path is returned unchanged")
    func anAbsolutePathIsReturnedUnchanged() throws {
        let executable = try makeFile(
            named: Self.agentName, in: tree.path, permissions: Self.executablePermissions
        )

        #expect(try resolver(searching: []).resolve(executable) == executable)
    }

    /// A path that exists but carries no executable bit is a mistake a person
    /// can fix, and the error says which file to fix.
    @Test("a path with no executable bit throws notExecutable")
    func aPathWithNoExecutableBitThrowsNotExecutable() throws {
        let file = try makeFile(
            named: Self.agentName, in: tree.path, permissions: Self.nonExecutablePermissions
        )

        #expect(throws: AgentCommandResolutionFailure.notExecutable(file)) {
            _ = try resolver(searching: []).resolve(file)
        }
    }

    /// A directory is not something to run, even though a directory carries an
    /// executable bit of its own.
    @Test("a directory throws notARegularFile")
    func aDirectoryThrowsNotARegularFile() throws {
        let directory = try makeDirectory(named: Self.agentName)

        #expect(throws: AgentCommandResolutionFailure.notARegularFile(directory)) {
            _ = try resolver(searching: []).resolve(directory)
        }
    }

    /// A path that names nothing at all is a typing mistake, and it is a
    /// different mistake from a file that cannot be run.
    @Test("a missing path throws noSuchFile")
    func aMissingPathThrowsNoSuchFile() throws {
        let missing = URL(fileURLWithPath: tree.path).appendingPathComponent(Self.agentName).path

        #expect(throws: AgentCommandResolutionFailure.noSuchFile(missing)) {
            _ = try resolver(searching: []).resolve(missing)
        }
    }

    /// Every value the resolver returns is one
    /// `AgentProcess.init(command:arguments:)` accepts, whichever of the three
    /// command shapes it came from.
    @Test("every resolved command is a path AgentProcess accepts")
    func everyResolvedCommandIsAPathAgentProcessAccepts() throws {
        let directory = try makeDirectory(named: "bin")
        try makeFile(named: Self.agentName, in: directory, permissions: Self.executablePermissions)
        let inTree = try makeFile(
            named: Self.agentName, in: tree.path, permissions: Self.executablePermissions
        )
        let subject = resolver(searching: [directory])

        expectAgentProcessAccepts(try subject.resolve(Self.agentName))
        expectAgentProcessAccepts(try subject.resolve("./\(Self.agentName)"))
        expectAgentProcessAccepts(try subject.resolve(inTree))
    }
}
