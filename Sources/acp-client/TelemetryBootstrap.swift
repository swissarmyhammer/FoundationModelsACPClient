import Foundation
import Logging
import OTel

/// Bootstraps the telemetry backends of the `acp-client` process.
///
/// Rule 1 of the OpenTelemetry design of 2026-09-28: only an executable links
/// swift-otel and bootstraps a backend, and the standard `OTEL_*` environment
/// variables configure it. Rule 6: an executable must always bootstrap
/// logging, because the default handler of swift-log writes to standard
/// output, and `cli-plan.md` §8 keeps standard output for the answer text
/// alone.
///
/// So this type keeps one invariant on every path: it bootstraps logging one
/// time, and never with a handler that writes to standard output.
///
/// - When `OTEL_EXPORTER_OTLP_ENDPOINT` is set and the SDK is not disabled,
///   logs, traces and metrics go to the OTLP exporters of swift-otel.
/// - In all other cases, logging goes to `SwiftLogNoOpLogHandler`, and tracing
///   and metrics stay on their no-op defaults. Standard error belongs to the
///   terminal layer of `AcpClientCore`, and the ACP diagnostics already reach
///   it through `ACPLogger`.
///
/// Logging is bootstrapped here, and not in `OTel.bootstrap`, for two reasons.
/// `OTel.bootstrap` bootstraps logs first and can then fail on metrics or
/// traces, and a second `LoggingSystem.bootstrap` after that would stop the
/// process. And with `OTEL_SDK_DISABLED=true`, `OTel.bootstrap` bootstraps no
/// system at all, which leaves the swift-log default on standard output.
///
/// The export services that swift-otel returns do not run yet. Until a later
/// change runs them and flushes them before the process exits, no record
/// leaves the process.
enum TelemetryBootstrap {
    /// The variable that turns the OTLP exporters on.
    private static let endpointVariable = "OTEL_EXPORTER_OTLP_ENDPOINT"

    /// The variable that turns the whole OpenTelemetry SDK off.
    private static let sdkDisabledVariable = "OTEL_SDK_DISABLED"

    /// The value of ``sdkDisabledVariable`` that turns the SDK off. The
    /// OpenTelemetry specification compares it without regard to case.
    private static let sdkDisabledValue = "true"

    /// The lowest level of the swift-otel diagnostic messages that reach
    /// standard error. The default level, `info`, writes one line for each
    /// bootstrapped system on each run, and `cli-plan.md` §8 gives a default
    /// run no standard error until it fails. `OTEL_LOG_LEVEL` can change it.
    private static let diagnosticLogLevel: OTel.Configuration.LogLevel = .warning

    /// The text that starts the line this type writes when a backend cannot
    /// be made.
    private static let failurePrefix = "acp-client: a telemetry backend is off"

    /// Bootstraps logging, tracing and metrics for this process.
    ///
    /// Call it one time, as the first statement of the process. swift-log
    /// stops the process on a second bootstrap.
    ///
    /// It reads the environment of the process, as swift-otel does for each
    /// `OTEL_*` variable, so the decision here and the configuration there
    /// come from the same variables.
    static func bootstrap() {
        guard exportsTelemetry(in: ProcessInfo.processInfo.environment) else {
            LoggingSystem.bootstrap(SwiftLogNoOpLogHandler.init)
            return
        }
        let configuration = exporterConfiguration()
        LoggingSystem.bootstrap(loggingFactory(configuration: configuration))
        bootstrapTracingAndMetrics(configuration: configuration)
    }

    /// Tells if the environment asks for the OTLP exporters.
    ///
    /// - Parameter environment: The environment to read.
    /// - Returns: `true` when ``endpointVariable`` holds a value and
    ///   ``sdkDisabledVariable`` does not turn the SDK off.
    private static func exportsTelemetry(in environment: [String: String]) -> Bool {
        guard let endpoint = environment[endpointVariable], !endpoint.isEmpty else {
            return false
        }
        return environment[sdkDisabledVariable]?.lowercased() != sdkDisabledValue
    }

    /// The swift-otel configuration for this process, before the environment
    /// overrides that swift-otel applies itself.
    ///
    /// - Returns: The default configuration, with diagnostic messages below
    ///   ``diagnosticLogLevel`` removed.
    private static func exporterConfiguration() -> OTel.Configuration {
        var configuration = OTel.Configuration.default
        configuration.diagnosticLogLevel = diagnosticLogLevel
        return configuration
    }

    /// Makes the log handler factory of the OTLP logs exporter.
    ///
    /// - Parameter configuration: The swift-otel configuration.
    /// - Returns: The factory of the exporter, or the factory of
    ///   `SwiftLogNoOpLogHandler` when the exporter cannot be made.
    private static func loggingFactory(
        configuration: OTel.Configuration
    ) -> @Sendable (String) -> any LogHandler {
        do {
            return try OTel.makeLoggingBackend(configuration: configuration).factory
        } catch {
            reportFailure(error)
            return SwiftLogNoOpLogHandler.init
        }
    }

    /// Bootstraps the OTLP traces and metrics exporters.
    ///
    /// Logs are disabled in the configuration given to `OTel.bootstrap`,
    /// because ``bootstrap()`` already bootstrapped logging.
    ///
    /// - Parameter configuration: The swift-otel configuration.
    private static func bootstrapTracingAndMetrics(configuration: OTel.Configuration) {
        var tracesAndMetrics = configuration
        tracesAndMetrics.logs.enabled = false
        do {
            // The returned service is not run yet. See the type documentation.
            _ = try OTel.bootstrap(configuration: tracesAndMetrics)
        } catch {
            reportFailure(error)
        }
    }

    /// Writes one line to standard error that says a backend cannot be made.
    ///
    /// The run continues without that backend: telemetry must not change the
    /// outcome of a turn.
    ///
    /// - Parameter error: The error that swift-otel gave.
    private static func reportFailure(_ error: any Error) {
        FileHandle.standardError.write(Data("\(failurePrefix): \(error)\n".utf8))
    }
}
