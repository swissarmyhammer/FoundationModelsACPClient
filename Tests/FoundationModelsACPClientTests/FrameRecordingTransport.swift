import Foundation
import FoundationModelsACP

/// A pass-through transport that records each line it reads from its inner
/// transport, in wire order, before it gives the bytes to its reader.
///
/// A test wraps the agent end of an in-memory pair with it, so the record
/// holds the frames of the client in the order that they crossed the wire. A
/// record in the handlers of the agent would race, because the agent handles
/// each message on a task of its own.
///
/// The transport never decodes and never reorders. The line splitting is the
/// `NDJSONFramer` of the wire package, so a chunk boundary can fall anywhere.
final class FrameRecordingTransport: ACPTransport, Sendable {
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The transport that this transport wraps.
    private let inner: any ACPTransport

    /// The task that reads the inner transport and forwards each chunk.
    private let forwarder: Task<Void, Never>

    /// Wraps one transport.
    ///
    /// - Parameters:
    ///   - inner: The transport to wrap.
    ///   - record: Receives the text of each line that this transport reads,
    ///     with no line terminator.
    init(wrapping inner: any ACPTransport, record: @escaping @Sendable (String) -> Void) {
        self.inner = inner
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        bytes = stream
        let task = Task {
            // Only this task touches the framer, so it needs no lock.
            var framer = NDJSONFramer()
            do {
                for try await chunk in inner.bytes {
                    for line in framer.append(chunk) {
                        record(String(decoding: line, as: UTF8.self))
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        forwarder = task
        continuation.onTermination = { _ in
            task.cancel()
        }
    }

    deinit {
        forwarder.cancel()
    }

    func write(_ data: Data) async throws {
        try await inner.write(data)
    }
}
