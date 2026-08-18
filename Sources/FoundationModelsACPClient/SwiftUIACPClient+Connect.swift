// M6: the host-facing attach point. One call wires this observable client
// over any `ACPTransport` — the in-process `InMemoryTransport.pair()` end,
// or the stdio transport an `AgentProcess` vends — and keeps
// `connectionState` true to the transport's life. The wire package's
// `ClientSideConnection` exposes no close callback, so this file wraps the
// transport: the wrapper forwards the bytes and gives exactly one
// disconnect signal when the stream stops, in either direction.

import Foundation
import FoundationModelsACP
import Synchronization

extension SwiftUIACPClient {
    /// Connects this client over `transport` and returns the connection
    /// that drives the agent.
    ///
    /// ``connectionState`` becomes ``ConnectionState/connected`` at once.
    /// It becomes ``ConnectionState/disconnected`` when the transport
    /// stops, for any cause: the agent died (its byte stream reached EOF or
    /// failed), or the host closed the returned connection. A dead agent
    /// therefore surfaces as observable state, never as a hang — the wire
    /// package already rejects each pending request with
    /// `ConnectionError.closed` on disconnect.
    ///
    /// One connection is active per client at a time. After a disconnect,
    /// the host may call this again with a fresh transport; the session
    /// state this client already holds stays as it is, and the host reloads
    /// it over the new connection itself. This package never reconnects on
    /// its own — see ``AgentProcess`` for the no-automatic-respawn policy.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional transport to run over.
    ///   - logger: Diagnostic sink; never stdout.
    /// - Returns: The client-side connection, ready to drive the agent.
    public func connect(
        over transport: any ACPTransport,
        logger: ACPLogger = .disabled
    ) async -> ClientSideConnection {
        connectionState = .connected
        let observed = DisconnectObservingTransport(wrapping: transport) { [weak self] in
            Task { @MainActor in
                self?.connectionState = .disconnected
            }
        }
        return await ClientSideConnection(stream: observed, logger: logger) { _ in self }
    }
}

/// A one-shot latch around the disconnect callback, so the two stop paths —
/// the inner stream ending, and the consumer tearing the stream down — give
/// exactly one signal between them.
final class DisconnectSignal: Sendable {
    /// Whether the callback already ran.
    private let fired = Mutex<Bool>(false)

    /// The callback to run exactly one time.
    private let notify: @Sendable () -> Void

    /// Creates the latch around `notify`.
    ///
    /// - Parameter notify: The callback to run exactly one time.
    init(_ notify: @escaping @Sendable () -> Void) {
        self.notify = notify
    }

    /// Runs the callback, the first time only. Later calls are no-ops.
    func fire() {
        let alreadyFired = fired.withLock { flag -> Bool in
            defer { flag = true }
            return flag
        }
        guard !alreadyFired else { return }
        notify()
    }
}

/// A pass-through transport that reports when its byte stream stops.
///
/// The wrapped transport's chunks flow through unchanged. `onDisconnect`
/// runs exactly one time, on the first of: the inner stream finishing (EOF —
/// the peer or the agent went away), the inner stream failing, or the
/// consumer tearing this stream down (the host closed the connection, which
/// cancels the read loop). The teardown path also cancels the forwarding
/// task, which ends the inner stream, so a wrapped ``AgentProcess``
/// transport tears its agent down on connection close.
final class DisconnectObservingTransport: ACPTransport, Sendable {
    /// The forwarded byte chunks, ending when the inner stream ends.
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The wrapped transport; `write(_:)` goes straight to it.
    private let inner: any ACPTransport

    /// The forwarding task; cancelled on stream teardown and on `deinit`.
    private let forwarder: Task<Void, Never>

    /// Wraps `inner` and arms the one-shot disconnect signal.
    ///
    /// - Parameters:
    ///   - inner: The transport to forward.
    ///   - onDisconnect: The callback that runs exactly one time when the
    ///     byte stream stops.
    init(wrapping inner: any ACPTransport, onDisconnect: @escaping @Sendable () -> Void) {
        self.inner = inner
        let signal = DisconnectSignal(onDisconnect)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.bytes = stream
        let task = Task {
            do {
                for try await chunk in inner.bytes {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            signal.fire()
        }
        self.forwarder = task
        continuation.onTermination = { _ in
            task.cancel()
            signal.fire()
        }
    }

    deinit {
        forwarder.cancel()
    }

    /// Delivers one chunk to the wrapped transport.
    ///
    /// - Parameter data: The bytes to send, already framed by the caller.
    /// - Throws: Rethrows the wrapped transport's write failure.
    func write(_ data: Data) async throws {
        try await inner.write(data)
    }
}
