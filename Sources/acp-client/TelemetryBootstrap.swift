import Foundation
import Logging
import OTel
import ServiceLifecycle

/// Bootstraps the telemetry backends of the `acp-client` process.
///
/// Rule 1 of the OpenTelemetry design of 2026-09-28: only an executable links
/// swift-otel and bootstraps a backend, and the standard `OTEL_*` environment
/// variables configure it. Rule 6: an executable must always bootstrap
/// logging. The default handler of swift-log writes to standard error, and
/// `cli-plan.md` §8 gives standard error to the terminal layer of
/// `AcpClientCore`. Log lines from the default handler would mix with the
/// output of that layer. Standard output holds the answer text alone.
///
/// So this type keeps one invariant on every path: it bootstraps logging one
/// time, and never with a handler that writes to standard output, or that
/// writes to standard error outside the terminal layer.
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
/// system at all, which leaves the swift-log default on standard error, where
/// the terminal layer owns the output.
///
/// swift-otel returns one export service for each backend it makes. This type
/// keeps them, and gives them back as ``TelemetryServices``, which runs them
/// for the life of the command and flushes them before the process exits.
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
    ///
    /// - Returns: The export services of each backend that was made. The set
    ///   is empty when telemetry is off, or when no backend could be made.
    static func bootstrap() -> TelemetryServices {
        guard exportsTelemetry(in: ProcessInfo.processInfo.environment) else {
            LoggingSystem.bootstrap(SwiftLogNoOpLogHandler.init)
            return TelemetryServices(services: [])
        }
        let configuration = exporterConfiguration()
        let logs = loggingBackend(configuration: configuration)
        LoggingSystem.bootstrap(logs.factory)
        let tracesAndMetrics = bootstrapTracingAndMetrics(configuration: configuration)
        return TelemetryServices(services: [logs.service, tracesAndMetrics].compactMap { $0 })
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

    /// Makes the OTLP logs exporter.
    ///
    /// - Parameter configuration: The swift-otel configuration.
    /// - Returns: The log handler factory of the exporter and its export
    ///   service. When the exporter cannot be made, the factory of
    ///   `SwiftLogNoOpLogHandler` and no service.
    private static func loggingBackend(
        configuration: OTel.Configuration
    ) -> (factory: @Sendable (String) -> any LogHandler, service: (any Service)?) {
        do {
            let backend = try OTel.makeLoggingBackend(configuration: configuration)
            return (backend.factory, backend.service)
        } catch {
            reportFailure(error)
            return (SwiftLogNoOpLogHandler.init, nil)
        }
    }

    /// Bootstraps the OTLP traces and metrics exporters.
    ///
    /// Logs are disabled in the configuration given to `OTel.bootstrap`,
    /// because ``bootstrap()`` already bootstrapped logging.
    ///
    /// - Parameter configuration: The swift-otel configuration.
    /// - Returns: The export service of the two exporters, or `nil` when they
    ///   cannot be made.
    private static func bootstrapTracingAndMetrics(configuration: OTel.Configuration) -> (any Service)? {
        var tracesAndMetrics = configuration
        tracesAndMetrics.logs.enabled = false
        do {
            return try OTel.bootstrap(configuration: tracesAndMetrics)
        } catch {
            reportFailure(error)
            return nil
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
