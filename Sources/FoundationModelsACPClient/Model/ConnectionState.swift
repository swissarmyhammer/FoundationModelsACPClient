import FoundationModelsACP

/// The connection state of a client, for a UI to observe.
///
/// Two states are equal when they have the same case. Two `failed` states are
/// equal for each pair of errors, so a UI can test for a failure with `==`
/// and read the error with a `switch`.
public enum ConnectionState: Sendable {
    /// No connection is open: the connection was never made, the agent
    /// closed its side, or the host closed the connection.
    case disconnected

    /// The connection is being made.
    case connecting

    /// The connection is open and serves the agent.
    case connected

    /// The read from the agent failed with the error. The connection is
    /// closed.
    case failed(any Error)

    /// Makes the state that a closed connection has.
    ///
    /// The end of input and a close by the host are both a normal
    /// disconnect. A failure of the input stream keeps its error.
    ///
    /// - Parameter reason: The reason that the connection closed.
    init(closedBecause reason: ConnectionCloseReason) {
        switch reason {
        case .endOfInput, .closedLocally:
            self = .disconnected
        case .transportFailed(let error):
            self = .failed(error)
        }
    }

    /// The case of the state, with no error.
    private var phase: Phase {
        switch self {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .failed: .failed
        }
    }

    /// The case of a state, with no associated value, so the state compares
    /// and hashes by case.
    private enum Phase: Hashable {
        /// The case ``ConnectionState/disconnected``.
        case disconnected

        /// The case ``ConnectionState/connecting``.
        case connecting

        /// The case ``ConnectionState/connected``.
        case connected

        /// The case ``ConnectionState/failed(_:)``, for each error.
        case failed
    }
}

extension ConnectionState: Hashable {
    /// Tells whether two states have the same case. The error of a failed
    /// state is not compared.
    ///
    /// - Parameters:
    ///   - lhs: The first state.
    ///   - rhs: The second state.
    /// - Returns: `true` when the two states have the same case.
    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        lhs.phase == rhs.phase
    }

    /// Hashes the case of the state. The error of a failed state is not
    /// hashed.
    ///
    /// - Parameter hasher: The hasher to use.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(phase)
    }
}
