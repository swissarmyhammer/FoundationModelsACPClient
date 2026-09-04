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
        }
    }
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
/// The run is bounded by ``TransportTestDeadline/limit``. A binary that hangs is
/// killed at the limit and the call throws, so the test that asked fails and the
/// suite goes on.
///
/// - Parameters:
///   - arguments: The command-line arguments for `acp-client`.
///   - standardInput: The bytes to give the run on its standard input, or `nil`
///     to give it an immediate end of file.
///   - environment: The whole environment for the run, or `nil` to inherit this
///     process's own.
/// - Returns: The finished run.
/// - Throws: A locator error, a spawn or file-system failure, or
///   ``CLITestSupportError/runTimedOut(arguments:limit:)``.
func runAcpClient(
    _ arguments: [String],
    standardInput: Data? = nil,
    environment: [String: String]? = nil
) async throws -> CLIResult {
    let inputFile = try standardInput.map { try writeStandardInputFile($0) }
    defer {
        if let inputFile {
            try? FileManager.default.removeItem(at: inputFile)
        }
    }

    let process = Process()
    process.executableURL = try acpClientBinaryURL()
    process.arguments = arguments
    if let environment {
        process.environment = environment
    }
    // A regular file rather than a pipe: the run reads it with no writer on the
    // other end, so nothing here can block on a full pipe buffer and nothing can
    // write to a binary that has already exited.
    process.standardInput = try inputFile.map { try FileHandle(forReadingFrom: $0) }
        ?? FileHandle.nullDevice
    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()
    process.standardOutput = standardOutputPipe
    process.standardError = standardErrorPipe

    try process.run()
    // Both pipes drain on child tasks that start before the wait. A full pipe
    // buffer blocks the child, so a run that wrote more than one buffer would
    // never exit if the reads came after.
    async let standardOutputData = readToEnd(standardOutputPipe.fileHandleForReading)
    async let standardErrorData = readToEnd(standardErrorPipe.fileHandleForReading)

    guard await exited(process, within: TransportTestDeadline.limit) else {
        kill(process.processIdentifier, SIGKILL)
        throw CLITestSupportError.runTimedOut(
            arguments: arguments,
            limit: TransportTestDeadline.limit
        )
    }
    return CLIResult(
        exitCode: process.terminationStatus,
        standardOutput: try await standardOutputData,
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

/// Writes the bytes a run gets on its standard input into a temporary file.
///
/// - Parameter data: The bytes to give the run.
/// - Returns: The file URL of the temporary file; the caller removes it.
/// - Throws: The write failure of the temporary file.
private func writeStandardInputFile(_ data: Data) throws -> URL {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("acp-client-stdin-\(UUID().uuidString)")
    try data.write(to: file, options: .atomic)
    return file
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
