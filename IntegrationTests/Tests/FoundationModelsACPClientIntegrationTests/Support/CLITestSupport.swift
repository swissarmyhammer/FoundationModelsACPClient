import Foundation

// The built `acp-client` binary, and the bounded runner the CLI suites drive it
// with.
//
// `IntegrationTests/Package.swift` names the `acp-client` EXECUTABLE product in
// this test target's dependencies, so SwiftPM builds that binary into the same
// products directory as this test bundle. ``acpClientBinaryURL()`` is what finds
// it there.
//
// The locator is a behavioural port of `BuiltProductLocator` in the sibling
// package FoundationModelsACPAgent, narrowed to the one executable this package
// builds. A test target cannot share source with a target in an other package,
// so the port is a copy on purpose, in the same way as the two copies of
// `TransportTestSupport.swift`.
//
// The runner opens the child's standard input rather than sharing this
// process's, because the prompt-source table of `cli-plan.md` §7 turns on what
// `isatty(3)` says about that one descriptor. A test process cannot make its
// OWN standard input a terminal, so the terminal row is reached by opening a
// pseudo-terminal and handing the child its slave end.

/// The product name of the CLI these suites run, as `../Package.swift` declares
/// it.
let acpClientExecutableName = "acp-client"

/// The failures of the CLI test support.
enum CLITestSupportError: Error, CustomStringConvertible {
    /// `argumentName` carried `value`, which holds a `..` path component.
    case pathTraversalRejected(argumentName: String, value: String)

    /// The candidate at `path`, derived from `derivedFromArgument`, is not a
    /// directory.
    case productsDirectoryNotFound(path: String, derivedFromArgument: String)

    /// No executable file named `name` stands in the directory `path`.
    case executableNotFound(name: String, directory: String)

    /// A run of `arguments` was still going when `limit` ended.
    case runTimedOut(arguments: [String], limit: Duration)

    /// A pseudo-terminal could not be opened, and `errno` says why.
    case pseudoTerminalUnavailable(errno: Int32)

    /// A human-readable description of this error.
    var description: String {
        switch self {
        case .pathTraversalRejected(let argumentName, let value):
            return """
                Rejected the \(argumentName) argument "\(value)": a ".." path component is not \
                allowed when deriving the test products directory.
                """
        case .productsDirectoryNotFound(let path, let derivedFromArgument):
            return """
                The derived products directory "\(path)" (from the argument "\(derivedFromArgument)") \
                does not exist or is not a directory; the test-bundle argument parsing may no longer \
                match this build's layout.
                """
        case .executableNotFound(let name, let directory):
            return """
                No \(name) executable stands in "\(directory)". `swift test --package-path \
                IntegrationTests` builds it there because the test target depends on the \
                `\(name)` executable product.
                """
        case .runTimedOut(let arguments, let limit):
            return """
                `\(acpClientExecutableName) \(arguments.joined(separator: " "))` was still running \
                after \(limit); it was killed so the suite could go on.
                """
        case .pseudoTerminalUnavailable(let errno):
            return """
                No pseudo-terminal could be opened (errno \(errno)), so no run can be given a \
                standard input that isatty(3) calls a terminal.
                """
        }
    }
}

/// What a bounded `acp-client` run gets on its standard input.
///
/// The three cases are the three descriptors the prompt-source table of
/// `cli-plan.md` §7 tells apart: an empty pipe, a file holding the prompt, and
/// a terminal.
///
/// The terminal case is why this is a value and not a `Data?`. A test process
/// cannot make its OWN standard input a terminal, and it must not touch the
/// descriptor the test runner owns, so the only way to reach the §7 row that
/// turns on `isatty` is to open a pseudo-terminal and hand the child its slave
/// end.
enum CLIStandardInput {
    /// An immediate end of file, which `isatty` reads as not a terminal.
    case endOfFile

    /// These bytes, from a regular file, which `isatty` reads as not a
    /// terminal.
    case bytes(Data)

    /// A pseudo-terminal, which `isatty` reads as a terminal and which holds no
    /// bytes to read.
    case terminal
}

/// Where a bounded `acp-client` run writes its standard output.
///
/// `cli-plan.md` §8 asks for the answer bytes verbatim, "in a terminal and in a
/// pipe alike", because "a rule that changes with a terminal cannot be tested
/// byte for byte". The two cases are the two descriptors a test can give the
/// run and then read back, and they differ in the ways a program that decided
/// by descriptor kind would notice: a pipe cannot seek and a regular file can.
enum CLIStandardOutput {
    /// A pipe, drained on a task of its own while the run goes.
    case pipe

    /// A regular file, read back once the run has exited.
    case file
}

/// The signals one bounded run receives while it is still going.
///
/// `cli-plan.md` §11 is about a signal that lands IN THE MIDDLE of a turn, and
/// nothing but a real signal to a real child process can measure it. A test
/// that merely sent the signal as fast as it could would measure the wrong
/// thing on a loaded machine: a signal that arrived before the turn started
/// reaches a `SIGINT` disposition this binary has not replaced yet, and one
/// that arrived after the turn ended reaches nothing at all. So the send waits
/// on ``readiness``, which the test points at a fact only a running turn can
/// produce.
struct CLISignals: Sendable {
    /// The signal number to send.
    let signal: Int32

    /// How many times to send it, back to back.
    ///
    /// §11 gives one press and two presses different behaviour, so this is the
    /// one thing that tells the two rows apart.
    let count: Int

    /// Answers whether the run has reached the point these signals mean to
    /// catch. It is polled until it answers `true` or the run's own bound ends.
    let readiness: @Sendable () -> Bool
}

/// One finished `acp-client` run.
///
/// The two streams stay `Data` rather than `String`, so a test can assert on the
/// bytes a stream carried. `cli-plan.md` §8 makes stdout the answer text and
/// nothing else, and byte-for-byte is how that is checked.
struct CLIResult {
    /// The process exit code.
    let exitCode: Int32

    /// Every byte the run wrote to its standard output.
    let standardOutput: Data

    /// Every byte the run wrote to its standard error.
    let standardError: Data
}

/// Locates the `acp-client` executable SwiftPM built beside the running test
/// bundle.
///
/// - Returns: The file URL of the executable.
/// - Throws: ``CLITestSupportError/pathTraversalRejected(argumentName:value:)``
///   or ``CLITestSupportError/productsDirectoryNotFound(path:derivedFromArgument:)``
///   when the products directory cannot be derived, and
///   ``CLITestSupportError/executableNotFound(name:directory:)``, which names
///   the directory it looked in, when no executable stands there.
func acpClientBinaryURL() throws -> URL {
    let directory = try productsDirectoryURL()
    let candidate = directory.appendingPathComponent(acpClientExecutableName)
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
        throw CLITestSupportError.executableNotFound(
            name: acpClientExecutableName,
            directory: directory.path
        )
    }
    return candidate
}

/// Runs the built `acp-client` with `arguments` and captures what it did.
///
/// The run is bounded. A binary that hangs is killed at the limit and the call
/// throws, so the test that asked fails and the suite goes on.
///
/// The default bound suits a subcommand that answers as fast as the agent does.
/// A subcommand that carries a wait of its own — `doctor`, whose fourth row
/// races `initialize` against a limit of its own — states a longer one, so that
/// the run this suite MEANS to take that long is not killed as a hang.
///
/// - Parameters:
///   - arguments: The command-line arguments for `acp-client`.
///   - standardInput: What the run gets on its standard input. The default is
///     an immediate end of file.
///   - standardOutput: Where the run writes its standard output. The default is
///     a pipe.
///   - environment: The whole environment for the run, or `nil` to inherit this
///     process's own.
///   - signals: The signals to send the run while it goes, or `nil` to send
///     none. The default is none.
///   - limit: The longest the run may take. The default is
///     ``TransportTestDeadline/limit``.
/// - Returns: The finished run.
/// - Throws: A locator error, a spawn or file-system failure,
///   ``CLITestSupportError/pseudoTerminalUnavailable(errno:)``, or
///   ``CLITestSupportError/runTimedOut(arguments:limit:)``.
func runAcpClient(
    _ arguments: [String],
    standardInput: CLIStandardInput = .endOfFile,
    standardOutput: CLIStandardOutput = .pipe,
    environment: [String: String]? = nil,
    signals: CLISignals? = nil,
    within limit: Duration = TransportTestDeadline.limit
) async throws -> CLIResult {
    let input = try StandardInputSource(standardInput)
    defer { input.tearDown() }
    let output = try StandardOutputSink(standardOutput)
    defer { output.tearDown() }

    let process = Process()
    process.executableURL = try acpClientBinaryURL()
    process.arguments = arguments
    if let environment {
        process.environment = environment
    }
    process.standardInput = input.handle
    let standardErrorPipe = Pipe()
    process.standardOutput = output.destination
    process.standardError = standardErrorPipe

    try process.run()
    // Every pipe drains on a child task that starts before the wait. A full
    // pipe buffer blocks the child, so a run that wrote more than one buffer
    // would never exit if the reads came after. The handles are bound out of
    // the sink first: an `async let` sends whatever its expression touches, and
    // the sink itself is read again below, after the wait.
    let outputPipeReader = output.pipeReader
    let errorPipeReader = standardErrorPipe.fileHandleForReading
    async let drainedOutput = drainedBytes(from: outputPipeReader)
    async let standardErrorData = readToEnd(errorPipeReader)
    // The sender is a child of this call rather than a `Task` of its own, so
    // it cannot outlive the run: an `async let` the caller never reads is
    // cancelled and awaited when this function leaves, on the throw below as
    // well as on the return.
    async let signalsSent: Void = deliver(signals, to: process.processIdentifier, within: limit)

    guard await exited(process, within: limit) else {
        kill(process.processIdentifier, SIGKILL)
        throw CLITestSupportError.runTimedOut(arguments: arguments, limit: limit)
    }
    // The sender has nothing left to do once the run has exited, and awaiting
    // it here is what keeps it a child of this call rather than a task the
    // result outlives.
    await signalsSent
    return CLIResult(
        exitCode: process.terminationStatus,
        standardOutput: try await output.bytesWritten(drainedFromPipe: drainedOutput),
        standardError: try await standardErrorData
    )
}

// MARK: - The products directory

/// The flag `swiftpm-testing-helper` passes the test-bundle path under.
private let testBundlePathFlag = "--test-bundle-path"

/// The suffix of a test bundle path, the fallback when ``testBundlePathFlag`` is
/// absent.
private let testBundleSuffix = ".xctest"

/// The path component that walks up one directory, which no argument this
/// locator reads may carry.
private let parentDirectoryComponent = ".."

/// How many path components stand between the executable inside a test bundle
/// (`<Bundle>.xctest/Contents/MacOS/<binary>`) and the products directory that
/// holds the bundle: the binary, `MacOS`, `Contents` and the bundle itself.
private let bundleDepthBelowProductsDirectory = 4

/// How many path components stand between a path that IS the products directory
/// entry and the directory itself: the entry alone.
private let entryDepthBelowProductsDirectory = 1

/// Locates the build products directory that holds the running test binary.
///
/// On Darwin, `swift test` hosts the swift-testing runner inside an `.xctest`
/// bundle that a separate `swiftpm-testing-helper` process launches with a
/// `--test-bundle-path` argument — read here, and not through
/// `Bundle.allBundles`, because that bundle never registers as an `NSBundle`. A
/// run that invokes the built bundle directly through `xcrun xctest <bundle>`
/// sets no such flag; there the bundle path is the positional argument with the
/// `.xctest` suffix, and its parent is the products directory. When neither
/// applies, the directory of this process's own executable is it.
///
/// Every candidate goes through the `..` check before it derives a path, and the
/// derived directory through the existence check before it is returned: a
/// `CommandLine` argument must not walk this resolution outside the real
/// products directory.
///
/// - Returns: The products directory.
/// - Throws: ``CLITestSupportError/pathTraversalRejected(argumentName:value:)``
///   or ``CLITestSupportError/productsDirectoryNotFound(path:derivedFromArgument:)``.
private func productsDirectoryURL() throws -> URL {
    let arguments = CommandLine.arguments
    if let flagIndex = arguments.firstIndex(of: testBundlePathFlag),
        arguments.indices.contains(flagIndex + 1)
    {
        return try productsDirectory(
            derivedFrom: arguments[flagIndex + 1],
            argumentName: testBundlePathFlag,
            levelsUp: bundleDepthBelowProductsDirectory
        )
    }
    if let bundleArgument = arguments.first(where: { $0.hasSuffix(testBundleSuffix) }) {
        return try productsDirectory(
            derivedFrom: bundleArgument,
            argumentName: "\(testBundleSuffix)-suffixed",
            levelsUp: entryDepthBelowProductsDirectory
        )
    }
    return try productsDirectory(
        derivedFrom: arguments[0],
        argumentName: "CommandLine.arguments[0]",
        levelsUp: entryDepthBelowProductsDirectory
    )
}

/// Derives the products directory from one `CommandLine` argument: the `..`
/// check, `levelsUp` parent steps, then the directory check.
///
/// - Parameters:
///   - argument: The argument value to derive from.
///   - argumentName: A label for `argument`, for the error message only.
///   - levelsUp: How many trailing path components to remove.
/// - Returns: The derived directory.
/// - Throws: ``CLITestSupportError/pathTraversalRejected(argumentName:value:)``
///   or ``CLITestSupportError/productsDirectoryNotFound(path:derivedFromArgument:)``.
private func productsDirectory(
    derivedFrom argument: String,
    argumentName: String,
    levelsUp: Int
) throws -> URL {
    guard !argument.split(separator: "/").contains(Substring(parentDirectoryComponent)) else {
        throw CLITestSupportError.pathTraversalRejected(argumentName: argumentName, value: argument)
    }
    var candidate = URL(fileURLWithPath: argument)
    for _ in 0..<levelsUp {
        candidate = candidate.deletingLastPathComponent()
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        throw CLITestSupportError.productsDirectoryNotFound(
            path: candidate.path,
            derivedFromArgument: argument
        )
    }
    return candidate
}

// MARK: - Running the process

/// The text that stands before the unique part of a standard-input file's name.
private let standardInputFileNamePrefix = "acp-client-stdin-"

/// The descriptor one run reads its standard input from, and the cleanup that
/// descriptor owes.
///
/// It is a value of its own because the three cases of ``CLIStandardInput``
/// open three different things and each has to be given back: a temporary file
/// is removed, a pseudo-terminal master is closed, and the null device is
/// neither.
private struct StandardInputSource {
    /// The handle the run reads its standard input from.
    let handle: FileHandle

    /// The temporary file behind ``handle``, or `nil` when there is none.
    private let file: URL?

    /// The master end of the pseudo-terminal behind ``handle``, or `nil` when
    /// there is none.
    ///
    /// It stays open for the whole run. Closing the master hangs the slave up,
    /// and a hung-up slave is no longer the terminal the run has to see.
    private let pseudoTerminalMaster: Int32?

    /// Opens the standard input one run asked for.
    ///
    /// The bytes go into a regular file rather than a pipe: the run reads it
    /// with no writer on the other end, so nothing here can block on a full
    /// pipe buffer and nothing can write to a binary that has already exited.
    ///
    /// - Parameter standardInput: What the run gets on its standard input.
    /// - Throws: The write failure of the temporary file, or
    ///   ``CLITestSupportError/pseudoTerminalUnavailable(errno:)``.
    init(_ standardInput: CLIStandardInput) throws {
        switch standardInput {
        case .endOfFile:
            handle = FileHandle.nullDevice
            file = nil
            pseudoTerminalMaster = nil
        case .bytes(let data):
            let written = try writeStandardInputFile(data)
            file = written
            handle = try FileHandle(forReadingFrom: written)
            pseudoTerminalMaster = nil
        case .terminal:
            let pseudoTerminal = try openPseudoTerminal()
            handle = FileHandle(fileDescriptor: pseudoTerminal.slave, closeOnDealloc: true)
            pseudoTerminalMaster = pseudoTerminal.master
            file = nil
        }
    }

    /// Closes the pseudo-terminal and removes the temporary file, where this
    /// source opened either.
    ///
    /// The removal is best effort: the run has already finished by the time a
    /// caller tears down, and a temporary file that outlives one run is not a
    /// reason to fail a test that otherwise passed.
    func tearDown() {
        if let pseudoTerminalMaster {
            close(pseudoTerminalMaster)
        }
        if let file {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// The text that stands before the unique part of a standard-output file's
/// name.
private let standardOutputFileNamePrefix = "acp-client-stdout-"

/// The descriptor one run writes its standard output to, and the cleanup that
/// descriptor owes.
///
/// It is a value of its own because the two cases of ``CLIStandardOutput`` are
/// read back at different moments. A pipe has to be drained WHILE the run goes,
/// or a full buffer blocks the child; a file is read AFTER the run exits, and
/// reading it early would race the writer.
private struct StandardOutputSink {
    /// What `Process.standardOutput` is set to: a `Pipe`, or a `FileHandle` on
    /// a regular file.
    let destination: Any

    /// The read end of the pipe behind ``destination``, or `nil` when the run
    /// writes a file.
    ///
    /// It is the handle rather than the whole `Pipe`, because the caller binds
    /// it out before it starts the draining task: an `async let` sends whatever
    /// its expression touches, and the sink itself is read again after the
    /// wait.
    let pipeReader: FileHandle?

    /// The file behind ``destination``, or `nil` when the run writes a pipe.
    private let file: URL?

    /// This process's own handle on ``file``, or `nil` when the run writes a
    /// pipe.
    ///
    /// `Process` duplicates the descriptor for the child, so this handle is
    /// this process's copy and closing it in ``tearDown()`` takes nothing from
    /// the run.
    private let fileHandle: FileHandle?

    /// Opens the standard output one run asked for.
    ///
    /// - Parameter standardOutput: Where the run writes its standard output.
    /// - Throws: The creation failure of the temporary file.
    init(_ standardOutput: CLIStandardOutput) throws {
        switch standardOutput {
        case .pipe:
            let opened = Pipe()
            destination = opened
            pipeReader = opened.fileHandleForReading
            file = nil
            fileHandle = nil
        case .file:
            let created = try writeTemporaryFile(Data(), prefix: standardOutputFileNamePrefix)
            let handle = try FileHandle(forWritingTo: created)
            destination = handle
            pipeReader = nil
            file = created
            fileHandle = handle
        }
    }

    /// Everything the finished run wrote to its standard output.
    ///
    /// - Parameter drained: What ``drainedBytes(from:)`` read off ``pipeReader``
    ///   while the run went, which is empty for a file.
    /// - Returns: The bytes, whichever descriptor carried them.
    /// - Throws: The read failure of the file.
    func bytesWritten(drainedFromPipe drained: Data) throws -> Data {
        guard let file else { return drained }
        return try Data(contentsOf: file)
    }

    /// Closes this process's handle and removes the temporary file, where this
    /// sink opened either.
    ///
    /// The removal is best effort, for the reason
    /// ``StandardInputSource/tearDown()`` states.
    func tearDown() {
        try? fileHandle?.close()
        if let file {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Writes the bytes a run gets on its standard input into a temporary file.
///
/// - Parameter data: The bytes to give the run.
/// - Returns: The file URL of the temporary file; the caller removes it.
/// - Throws: The write failure of the temporary file.
private func writeStandardInputFile(_ data: Data) throws -> URL {
    try writeTemporaryFile(data, prefix: standardInputFileNamePrefix)
}

/// Opens a pseudo-terminal and gives back both of its ends.
///
/// The child reads its standard input from the slave end, and `isatty(3)` calls
/// that end a terminal. That is the one reading a regular file and a pipe both
/// fail, and it is what the third row of the prompt-source table of
/// `cli-plan.md` §7 turns on.
///
/// - Returns: The master end, which the caller holds open for the whole run,
///   and the slave end, which the child reads.
/// - Throws: ``CLITestSupportError/pseudoTerminalUnavailable(errno:)``.
private func openPseudoTerminal() throws -> (master: Int32, slave: Int32) {
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    guard master >= 0 else {
        throw CLITestSupportError.pseudoTerminalUnavailable(errno: errno)
    }
    do {
        // `errno` is read at the throw, before the `catch` runs any call of its
        // own, so each failure below reports the call that really failed.
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            throw CLITestSupportError.pseudoTerminalUnavailable(errno: errno)
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            throw CLITestSupportError.pseudoTerminalUnavailable(errno: errno)
        }
        return (master, slave)
    } catch {
        // Nothing took the master over, and a suite that opens one per test
        // cannot afford to leak it.
        close(master)
        throw error
    }
}

/// Reads one file handle to its end.
///
/// - Parameter handle: The handle to read.
/// - Returns: Every byte the handle carried, which is empty at an immediate end
///   of file.
/// - Throws: The read failure of the handle.
private func readToEnd(_ handle: FileHandle) throws -> Data {
    try handle.readToEnd() ?? Data()
}

/// Drains one run's standard-output pipe, where the run was given a pipe at
/// all.
///
/// A `nil` handle is a run whose standard output went to a regular file, and a
/// file needs no draining: nothing can block on it, and
/// ``StandardOutputSink/bytesWritten(drainedFromPipe:)`` reads it once the run
/// has exited.
///
/// - Parameter handle: The read end of the pipe, or `nil` for a file.
/// - Returns: Every byte the pipe carried, or nothing for a file.
/// - Throws: The read failure of the pipe.
private func drainedBytes(from handle: FileHandle?) throws -> Data {
    guard let handle else { return Data() }
    return try readToEnd(handle)
}

/// The smallest pid this support will ever signal.
///
/// `kill(2)` reads 0 as "every process in the sender's OWN process group" and a
/// negative number as "an other process group", so a pid that is not strictly
/// positive would signal the TEST RUNNER rather than the run under test. A
/// spawn that has not happened yet answers 0, which is exactly the value this
/// guard refuses.
private let smallestSignallablePid: pid_t = 1

/// Waits for the run to reach the point `signals` means to catch, and then
/// sends them.
///
/// A send that never becomes ready is not a failure of its own: the run under
/// it then ends whichever way it was going to end, and the test that asked for
/// the signals fails on the exit code or the bytes it asserted. That keeps the
/// failure the test's own claim rather than a second story about the harness.
///
/// - Parameters:
///   - signals: The signals to send, or `nil` to send none.
///   - pid: The pid of the run under test.
///   - limit: The longest to wait for readiness, which is the run's own bound.
private func deliver(_ signals: CLISignals?, to pid: pid_t, within limit: Duration) async {
    guard let signals, pid >= smallestSignallablePid else { return }
    guard await eventually(within: limit, { signals.readiness() }) else { return }
    for _ in 0..<signals.count {
        kill(pid, signals.signal)
    }
}

/// Waits for `process` to exit, and gives up at `limit`.
///
/// The wait polls rather than taking a termination handler, which keeps this
/// helper the same shape as ``eventually(within:_:)`` and leaves nothing to
/// resume twice when the limit and the exit land together.
///
/// - Parameters:
///   - process: The process to wait for.
///   - limit: The longest time to wait.
/// - Returns: `true` when the process exited before the limit ended.
private func exited(_ process: Process, within limit: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while process.isRunning && clock.now < deadline {
        try? await Task.sleep(for: TransportTestDeadline.pollInterval)
    }
    return !process.isRunning
}
