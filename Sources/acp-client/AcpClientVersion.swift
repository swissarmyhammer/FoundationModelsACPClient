/// The version `acp-client --version` reports.
///
/// One constant, so the flag and the tests can never disagree about what this
/// binary calls itself.
public enum AcpClientVersion {
    /// The current version, as three dot-separated numbers.
    public static let current = "0.1.0"
}
