import Foundation
import FoundationModelsACPClient
import Logging
import TelemetryTestSupport
import Testing

/// Tests the telemetry vocabulary of the library, and the rule that the
/// library and the command-line client use the telemetry APIs only.
///
/// Rule 1 of the OpenTelemetry design of 2026-09-28: a library uses only the
/// `Tracing`, `Logging` and `Metrics` APIs, and only the `acp-client`
/// executable bootstraps a backend. Rule 3: each package keeps its telemetry
/// names in one vocabulary file, and each name starts with the module name.
@Suite("ACPClientTelemetry vocabulary")
struct ACPClientTelemetryVocabularyTests {
    /// The text that each span name, metric name and logger label starts with.
    private static let requiredPrefix = "FoundationModelsACPClient."

    /// The directories of the two targets that must bootstrap no backend: the
    /// library and the library of the command-line client. The thin
    /// `acp-client` executable is not in this list, because it is the one
    /// target that bootstraps the backend.
    private static let scannedDirectories = [
        "Sources/FoundationModelsACPClient",
        "Sources/AcpClientCore",
    ]

    /// The calls that install a telemetry backend. Only the `acp-client`
    /// executable makes one of them.
    private static let backendBootstrapCalls = [
        "LoggingSystem.bootstrap",
        "MetricsSystem.bootstrap",
        "InstrumentationSystem.bootstrap",
        "OTel.bootstrap",
    ]

    /// The Apple unified-logging module. The library logs through swift-log.
    private static let appleLoggingModule = "os"

    /// The Apple signpost type. The library traces through
    /// swift-distributed-tracing.
    private static let appleSignpostType = "OSSignposter"

    @Test("each span name, metric name and logger label starts with the module prefix")
    func eachNameStartsWithTheModulePrefix() {
        let names = [
            ACPClientTelemetry.logLabel,
            ACPClientTelemetry.SpanName.request,
            ACPClientTelemetry.MetricName.requests,
            ACPClientTelemetry.MetricName.requestDuration,
            ACPClientTelemetry.MetricName.requestErrors,
        ]
        let unprefixed = names.filter { !$0.hasPrefix(Self.requiredPrefix) }
        #expect(
            unprefixed.isEmpty,
            "Each name must start with \(Self.requiredPrefix). These do not: \(unprefixed)"
        )
    }

    @Test("the attribute keys follow the OpenTelemetry semantic conventions")
    func theAttributeKeysFollowTheSemanticConventions() {
        #expect(ACPClientTelemetry.AttributeKey.rpcMethod == "rpc.method")
        #expect(ACPClientTelemetry.AttributeKey.sessionID == "session.id")
        #expect(ACPClientTelemetry.AttributeKey.errorCode == "rpc.jsonrpc.error_code")
    }

    @Test("each log metadata key is the attribute key of the same value")
    func eachLogMetadataKeyIsTheAttributeKey() {
        #expect(ACPClientTelemetry.LogMetadataKey.rpcMethod == ACPClientTelemetry.AttributeKey.rpcMethod)
        #expect(ACPClientTelemetry.LogMetadataKey.sessionID == ACPClientTelemetry.AttributeKey.sessionID)
        #expect(ACPClientTelemetry.LogMetadataKey.errorCode == ACPClientTelemetry.AttributeKey.errorCode)
    }

    @Test("a logger made with the vocabulary label at call time writes to the capture")
    func aLoggerMadeAtCallTimeWritesToTheCapture() async throws {
        let message = "vocabulary probe"
        try await TelemetryCapture.run(forbidding: []) { context in
            Logger(label: ACPClientTelemetry.logLabel).info("\(message)")
            let messages = context.logRecords.map { "\($0.message)" }
            #expect(messages.contains(message), "The capture holds \(messages).")
        }
    }

    @Test("the library and the client library bootstrap no telemetry backend")
    func noScannedTargetBootstrapsABackend() throws {
        let violations = try Self.scannedFiles().flatMap { file in
            try Self.bootstrapCallViolations(in: file)
        }
        #expect(violations.isEmpty, "Only acp-client may bootstrap a backend. Found: \(violations)")
    }

    @Test("the library and the client library use neither os logging nor signposts")
    func noScannedTargetUsesAppleLogging() throws {
        let violations = try Self.scannedFiles().flatMap { file in
            try Self.appleLoggingViolations(in: file)
        }
        #expect(violations.isEmpty, "Use the Logging and Tracing APIs instead. Found: \(violations)")
    }

    /// Returns each Swift file of the scanned targets.
    ///
    /// - Returns: The URL of each Swift file below ``scannedDirectories``.
    /// - Throws: An error when a directory cannot be read, or when the walk
    ///   finds no Swift file.
    private static func scannedFiles() throws -> [URL] {
        let files = try RepositoryFile.swiftSourceFiles(underAnyOf: scannedDirectories)
        try #require(!files.isEmpty, "The scan found no Swift files below \(scannedDirectories).")
        return files
    }

    /// Returns each backend bootstrap call in one file.
    ///
    /// - Parameter file: The Swift file to read.
    /// - Returns: One `file: call` line for each call that the file names.
    /// - Throws: An error when the file cannot be read.
    private static func bootstrapCallViolations(in file: URL) throws -> [String] {
        let text = try String(contentsOf: file, encoding: .utf8)
        return backendBootstrapCalls
            .filter { text.contains($0) }
            .map { "\(file.lastPathComponent): \($0)" }
    }

    /// Returns each use of Apple unified logging or of signposts in one file.
    ///
    /// - Parameter file: The Swift file to read.
    /// - Returns: One `file: use` line for each `import os` statement, and one
    ///   for a use of `OSSignposter`.
    /// - Throws: An error when the file cannot be read.
    private static func appleLoggingViolations(in file: URL) throws -> [String] {
        let imports = try SwiftImports.modules(in: file)
            .filter { $0 == appleLoggingModule }
            .map { "\(file.lastPathComponent): import \($0)" }
        let text = try String(contentsOf: file, encoding: .utf8)
        let signposts = text.contains(appleSignpostType) ? ["\(file.lastPathComponent): \(appleSignpostType)"] : []
        return imports + signposts
    }
}
