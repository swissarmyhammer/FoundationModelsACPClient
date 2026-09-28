import AcpClientCore

/// The process entry point of the `acp-client` binary.
///
/// This type and ``TelemetryBootstrap`` are all that this target holds.
/// Everything else the binary does lives in the `AcpClientCore` library,
/// because SwiftPM publishes no importable module for an executable product
/// across a package boundary: the `IntegrationTests` package can
/// `import AcpClientCore`, and could never have imported an `acp-client`
/// executable target.
///
/// The attribute is here rather than on ``AcpClientCore/AcpClient`` because
/// `@main` marks the entry point of the module that becomes the executable.
/// Keeping the root command in the library is what holds the rest of the
/// command tree internal.
@main
struct AcpClientMain {
    /// Bootstraps telemetry, then runs the command-line client, and never
    /// returns.
    ///
    /// ``TelemetryBootstrap/bootstrap()`` comes first, so that no
    /// log record can reach the default handler of swift-log, which writes to
    /// standard output. ``AcpClientCore/AcpClient/main()`` then parses the
    /// command line, runs the subcommand, and ends the process with the code
    /// `cli-plan.md` §9 gives the outcome.
    static func main() async {
        TelemetryBootstrap.bootstrap()
        await AcpClient.main()
    }
}
