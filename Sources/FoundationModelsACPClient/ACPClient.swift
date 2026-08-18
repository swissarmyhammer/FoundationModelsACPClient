import FoundationModelsACP

/// A namespace for package-level facts about this ACP client.
///
/// This package implements the ACP Client role. It depends only on the ACP
/// wire (`FoundationModelsACP`) and on Observation. It must not depend on the
/// agent runtime or on a view framework; a test enforces that boundary.
public enum ACPClient {
    /// The ACP protocol version that this client supports and sends during
    /// `initialize`.
    public static let supportedProtocolVersion: ProtocolVersion = .v2

    /// The client capabilities that this client sends during `initialize`.
    ///
    /// ACP stable v2 defines no standard client capability field, and this
    /// client implements no unstable extension. The value is therefore the
    /// empty capability set: the client advertises only the methods it
    /// implements, and nothing more.
    public static let advertisedCapabilities = ClientCapabilities()
}
