// `FrameTeeTransport` — the `--frames` half of `cli-plan.md` §6.1: "`--frames`
// is the reason the binary exists. It shows the protocol exchange, so a person
// can see what an agent sent."
//
// It is a pass-through wrapper and nothing more. `AgentProcess` vends its
// transport as `any ACPTransport`, and `SwiftUIACPClient.connect(over:)` takes
// any transport, so the tee slots between the two and needs no change in the
// wire package and no change in this package's library. The shape is the shape
// of `DisconnectObservingTransport` in the library's
// `SwiftUIACPClient+Connect.swift`: a forwarding task over the inner stream, a
// `write(_:)` that goes straight to the inner transport, and a task the stream
// teardown and `deinit` both cancel.
//
// The tee never decodes, never re-encodes and never reorders. A person
// debugging an agent needs the bytes the agent actually sent, malformed JSON
// and all, so the only thing this file takes off a line is the newline that
// framed it.
//
// The line splitting is the wire package's `NDJSONFramer`, not a splitter of
// this file's own. `ACPTransport` says chunk boundaries "are arbitrary — they
// need not align with lines or UTF-8 codepoints", and that framer is the
// package's answer to exactly that: it buffers a partial line across chunks,
// and its `finish()` gives back a tail the stream ended without terminating.

import Foundation
import FoundationModelsACP

/// A pass-through transport that copies the ndJSON exchange to a sink, one
/// line per call.
///
/// The wrapped transport's chunks flow through unchanged, byte for byte. Every
/// whole line crossing in either direction also reaches `sink`, prefixed with
/// the mark of its direction, so a person watching one mixed log can tell what
/// the agent sent from what this client sent. Production points the sink at
/// stderr, because stdout carries the answer.
///
/// A line reaches the sink at the moment its crossing is a fact: an inbound
/// line as soon as it is read from the agent, before the consumer sees the
/// chunk; an outbound line after the inner transport accepted it. So a line in
/// the log is a line that moved, and the two directions read in the order the
/// exchange happened.
final class FrameTeeTransport: ACPTransport, Sendable {
    /// The prefix on each line the agent sent to this client.
    ///
    /// This mark and ``outboundMark`` are fixed ASCII, and they differ in
    /// their first byte, so a person can sort a mixed log and get the two
    /// directions apart from each other.
    static let inboundMark = "<< "

    /// The prefix on each line this client sent to the agent.
    static let outboundMark = ">> "

    /// The tag between ``inboundMark`` and a trailing line that the stream
    /// ended without terminating.
    ///
    /// Such a line is reported rather than dropped: an agent that died
    /// mid-message left the half message that says where it died, and that is
    /// the one line the person debugging it most needs.
    static let incompleteTag = "[incomplete] "

    /// The ndJSON frame terminator.
    private static let frameTerminator: UInt8 = 0x0A

    /// The forwarded byte chunks, ending when the inner stream ends.
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The wrapped transport; ``write(_:)`` goes straight to it.
    private let inner: any ACPTransport

    /// Receives one line of the exchange per call, marked with its direction
    /// and carrying no terminator.
    private let sink: @Sendable (String) -> Void

    /// The forwarding task; cancelled on stream teardown and on `deinit`.
    private let forwarder: Task<Void, Never>

    /// Wraps `inner` and copies the exchange to `sink`.
    ///
    /// - Parameters:
    ///   - inner: The transport to forward.
    ///   - sink: Receives one marked line per call, without its terminator.
    ///     It is called from the forwarding task and from ``write(_:)``, so it
    ///     must tolerate calls from more than one task.
    init(wrapping inner: any ACPTransport, sink: @escaping @Sendable (String) -> Void) {
        self.inner = inner
        self.sink = sink
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.bytes = stream
        let task = Task {
            // The framer lives in the task, and no other task touches it, so
            // the buffered partial line needs no lock.
            var framer = NDJSONFramer()
            do {
                for try await chunk in inner.bytes {
                    for line in framer.append(chunk) {
                        sink(Self.inboundMark + Self.text(of: line))
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            // Both stop paths land here, the clean end of stream and the
            // failure, and either one can leave a partial line buffered.
            if let tail = framer.finish() {
                sink(Self.inboundMark + Self.incompleteTag + Self.text(of: tail))
            }
        }
        self.forwarder = task
        continuation.onTermination = { _ in
            task.cancel()
        }
    }

    deinit {
        forwarder.cancel()
    }

    /// Delivers one chunk to the wrapped transport, and copies it to the sink.
    ///
    /// The chunk is not run through a framer. `ACPTransport.write(_:)` is
    /// contracted to be atomic, and `NDJSONCodec.encode(_:)` terminates each
    /// message with exactly one newline, so one call is one frame. Buffering
    /// this side would only hold back the last frame this client ever sends.
    ///
    /// - Parameter data: The bytes to send, already framed by the caller.
    /// - Throws: Rethrows the wrapped transport's write failure. A write that
    ///   throws reached no wire, so it reaches no sink either.
    func write(_ data: Data) async throws {
        try await inner.write(data)
        sink(Self.outboundMark + Self.text(of: Self.withoutTerminator(data)))
    }

    /// Renders one line's bytes as the text the sink takes.
    ///
    /// Invalid UTF-8 becomes the replacement character rather than nothing,
    /// because a line an agent mis-encoded is still a line worth seeing.
    ///
    /// - Parameter line: The bytes of one line, without its terminator.
    /// - Returns: The line as text.
    private static func text(of line: Data) -> String {
        String(decoding: line, as: UTF8.self)
    }

    /// Drops the frame terminator from one outgoing chunk.
    ///
    /// The sink takes one line per call and adds its own line ending, the way
    /// `ACPLogger.standardError` does, so the terminator would print a blank
    /// line between frames. Framing is all this removes; the content of the
    /// line is untouched.
    ///
    /// - Parameter data: One outgoing chunk.
    /// - Returns: The chunk without a single trailing newline, if it had one.
    private static func withoutTerminator(_ data: Data) -> Data {
        data.last == frameTerminator ? data.dropLast() : data
    }
}
