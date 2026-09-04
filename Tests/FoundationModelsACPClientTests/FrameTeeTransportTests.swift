import Foundation
import FoundationModelsACP
import Testing

@testable import AcpClientCore

// These tests cover `FrameTeeTransport`, the `--frames` tee of `cli-plan.md`
// §6.1, with one test for each acceptance row of the card.
//
// Every test drives the tee over `InMemoryTransport.pair()`. One end of the
// pair is the transport the tee wraps; the other end stands for the agent.
// That pair hands each `write(_:)` to the peer as the one chunk it was given,
// so a test chooses where a chunk boundary falls — inside a line, and inside a
// codepoint — which is the whole subject here.
//
// No test spawns a process. The suite that runs a real agent over stdio lives
// in the nested `IntegrationTests` package, and the row that puts `--frames`
// on a real exchange belongs to that suite, not to this one.

/// The byte shaping these tests share: making a line, cutting it, and putting
/// the pieces back together.
private enum TeeBytes {
    /// The byte offset of the first boundary of the three-chunk split.
    ///
    /// Its only requirement is that it falls inside the message and before
    /// ``secondChunkBoundary``, so that no chunk holds a whole line.
    static let firstChunkBoundary = 10

    /// The byte offset of the second boundary of the three-chunk split.
    static let secondChunkBoundary = 25

    /// Renders one ndJSON message as the line the wire carries.
    ///
    /// - Parameter message: The message text, without a terminator.
    /// - Returns: The message and one newline, as bytes.
    static func line(_ message: String) -> Data {
        Data((message + "\n").utf8)
    }

    /// Joins byte chunks into one buffer, so an assertion compares bytes and
    /// not chunk boundaries.
    ///
    /// - Parameter chunks: The chunks, in arrival order.
    /// - Returns: The chunks end to end.
    static func joined(_ chunks: [Data]) -> Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }

    /// Cuts one line into three chunks, at ``firstChunkBoundary`` and
    /// ``secondChunkBoundary``.
    ///
    /// - Parameter line: The bytes to cut, longer than ``secondChunkBoundary``.
    /// - Returns: The three chunks, in order.
    static func threeChunks(of line: Data) -> [Data] {
        let middleLength = secondChunkBoundary - firstChunkBoundary
        return [
            Data(line.prefix(firstChunkBoundary)),
            Data(line.dropFirst(firstChunkBoundary).prefix(middleLength)),
            Data(line.dropFirst(secondChunkBoundary)),
        ]
    }
}

/// A ``FrameTeeTransport`` wired over an in-memory transport pair, with every
/// teed line and every byte that crossed it captured.
///
/// The two reader tasks start in `init`, so a chunk written before the test
/// body reads anything is still recorded. The tee writes from its forwarding
/// task while the test body reads, so each capture is a ``ThreadSafeBuffer``
/// and not a plain array.
private final class TeeHarness: Sendable {
    /// The end of the pair that stands for the agent.
    private let agentEnd: InMemoryTransport

    /// The end of the pair the tee wraps.
    private let clientEnd: InMemoryTransport

    /// The value under test.
    let tee: FrameTeeTransport

    /// Every line the tee gave its sink, in order.
    private let sinkLines: ThreadSafeBuffer<String>

    /// Every chunk the consumer read from the tee, in order.
    private let consumedChunks: ThreadSafeBuffer<Data>

    /// Every chunk that reached the agent end, in order.
    private let agentChunks: ThreadSafeBuffer<Data>

    /// Reads the tee's byte stream to its end.
    private let consumer: Task<Void, any Error>

    /// Reads the agent end's byte stream to its end.
    private let agentReader: Task<Void, any Error>

    /// Builds the pair, the tee over it, and the two readers.
    init() {
        let lines = ThreadSafeBuffer<String>()
        let consumed = ThreadSafeBuffer<Data>()
        let reachingAgent = ThreadSafeBuffer<Data>()
        let (agent, client) = InMemoryTransport.pair()
        let transport = FrameTeeTransport(wrapping: client) { lines.append($0) }
        let teeBytes = transport.bytes
        let agentBytes = agent.bytes

        sinkLines = lines
        consumedChunks = consumed
        agentChunks = reachingAgent
        agentEnd = agent
        clientEnd = client
        tee = transport
        consumer = Task {
            for try await chunk in teeBytes { consumed.append(chunk) }
        }
        agentReader = Task {
            for try await chunk in agentBytes { reachingAgent.append(chunk) }
        }
    }

    deinit {
        consumer.cancel()
        agentReader.cancel()
    }

    /// Sends one chunk from the agent, exactly as given.
    ///
    /// - Parameter chunk: The bytes to deliver, cut wherever the test wants.
    /// - Throws: Rethrows the in-memory transport's write failure.
    func agentSends(_ chunk: Data) async throws {
        try await agentEnd.write(chunk)
    }

    /// Ends the agent's byte stream, as a dead agent or a closed pipe does.
    func agentStops() {
        agentEnd.close()
    }

    /// Ends the client's outgoing direction, so the agent's reader finishes.
    func clientStops() {
        clientEnd.close()
    }

    /// Waits until the tee's byte stream has ended and its consumer has read
    /// everything the tee forwarded.
    func waitForEndOfStream() async {
        _ = try? await consumer.value
    }

    /// Waits until the agent has read everything the tee wrote to it.
    ///
    /// Call ``clientStops()`` first; without it the agent's stream never ends.
    func waitForAgentEndOfStream() async {
        _ = try? await agentReader.value
    }

    /// Every line the tee gave its sink, in order.
    var teedLines: [String] {
        sinkLines.elements
    }

    /// Everything the consumer read from the tee, end to end.
    var bytesReachingTheConsumer: Data {
        TeeBytes.joined(consumedChunks.elements)
    }

    /// Everything that reached the agent end, end to end.
    var bytesReachingTheAgent: Data {
        TeeBytes.joined(agentChunks.elements)
    }
}

@Suite("acp-client ndJSON frame tee")
struct FrameTeeTransportTests {
    /// How many messages the arrival-order test sends.
    private static let orderedMessageCount = 5

    /// How far into the multi-byte character the split test cuts.
    ///
    /// One byte in leaves a truncated codepoint at the end of the first chunk
    /// and a headless one at the start of the second, so neither chunk on its
    /// own is valid UTF-8.
    private static let bytesIntoTheCodepoint = 1

    /// The inner transport's bytes reach the consumer unchanged, byte for byte.
    @Test("the inner transport's bytes reach the consumer unchanged")
    func innerBytesReachTheConsumerUnchanged() async throws {
        let harness = TeeHarness()
        let chunks = [
            Data(#"{"id":1}"#.utf8),
            Data("\n{\"id\":2}\n".utf8),
        ]

        for chunk in chunks {
            try await harness.agentSends(chunk)
        }
        harness.agentStops()
        await harness.waitForEndOfStream()

        #expect(harness.bytesReachingTheConsumer == TeeBytes.joined(chunks))
    }

    /// A message split across three chunks is teed one time, as one whole line.
    @Test("a message split across three chunks is teed one time, as one line")
    func aSplitMessageIsTeedAsOneLine() async throws {
        let harness = TeeHarness()
        let message = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#

        for chunk in TeeBytes.threeChunks(of: TeeBytes.line(message)) {
            try await harness.agentSends(chunk)
        }
        harness.agentStops()
        await harness.waitForEndOfStream()

        #expect(harness.teedLines == [FrameTeeTransport.inboundMark + message])
    }

    /// Two messages inside one chunk are teed as two lines.
    @Test("two messages in one chunk are teed as two lines")
    func twoMessagesInOneChunkAreTeedAsTwoLines() async throws {
        let harness = TeeHarness()
        let first = #"{"id":1}"#
        let second = #"{"id":2}"#
        let expected = [
            FrameTeeTransport.inboundMark + first,
            FrameTeeTransport.inboundMark + second,
        ]

        try await harness.agentSends(TeeBytes.joined([TeeBytes.line(first), TeeBytes.line(second)]))
        harness.agentStops()
        await harness.waitForEndOfStream()

        #expect(harness.teedLines == expected)
    }

    /// An outbound write is teed, and it reaches the inner transport.
    @Test("an outbound write is teed and reaches the inner transport")
    func anOutboundWriteIsTeedAndReachesTheInnerTransport() async throws {
        let harness = TeeHarness()
        let message = #"{"id":1,"method":"session/prompt"}"#

        try await harness.tee.write(TeeBytes.line(message))
        harness.clientStops()
        await harness.waitForAgentEndOfStream()

        #expect(harness.teedLines == [FrameTeeTransport.outboundMark + message])
        #expect(harness.bytesReachingTheAgent == TeeBytes.line(message))
    }

    /// Each line carries its direction mark, and the two marks differ.
    ///
    /// The marks are spelled here rather than read from the type, because this
    /// test is what pins them: reading the constants would assert only that a
    /// value equals itself.
    @Test("each line carries its direction mark, and the two marks differ")
    func eachLineCarriesItsDirectionMark() async throws {
        let harness = TeeHarness()
        let sent = #"{"id":1}"#
        let received = #"{"id":2}"#

        try await harness.tee.write(TeeBytes.line(sent))
        try await harness.agentSends(TeeBytes.line(received))
        harness.agentStops()
        await harness.waitForEndOfStream()

        #expect(harness.teedLines == [">> " + sent, "<< " + received])
    }

    /// A trailing partial line at end of stream is teed as incomplete, and is
    /// not silently dropped.
    @Test("a trailing partial line at end of stream is teed as incomplete")
    func aTrailingPartialLineIsTeedAsIncomplete() async throws {
        let harness = TeeHarness()
        let whole = #"{"id":1}"#
        let partial = #"{"id":2,"me"#
        let expected = [
            FrameTeeTransport.inboundMark + whole,
            FrameTeeTransport.inboundMark + FrameTeeTransport.incompleteTag + partial,
        ]

        try await harness.agentSends(TeeBytes.joined([TeeBytes.line(whole), Data(partial.utf8)]))
        harness.agentStops()
        await harness.waitForEndOfStream()

        // The tail reaches the sink after the stream has finished, so the wait
        // above does not cover it.
        let bothLines = await eventually { harness.teedLines.count == expected.count }
        #expect(bothLines)
        #expect(harness.teedLines == expected)
    }

    /// A chunk boundary inside a multi-byte codepoint changes neither the
    /// forwarded bytes nor the teed line.
    @Test("a codepoint split across chunks is forwarded unchanged and teed whole")
    func aSplitCodepointIsForwardedUnchangedAndTeedWhole() async throws {
        let harness = TeeHarness()
        // Three bytes in UTF-8, so a cut one byte in falls inside it.
        let character = "日"
        let head = #"{"text":""#
        let message = head + character + #""}"#
        let line = TeeBytes.line(message)
        let cut = head.utf8.count + Self.bytesIntoTheCodepoint

        try await harness.agentSends(Data(line.prefix(cut)))
        try await harness.agentSends(Data(line.dropFirst(cut)))
        harness.agentStops()
        await harness.waitForEndOfStream()

        #expect(harness.bytesReachingTheConsumer == line)
        #expect(harness.teedLines == [FrameTeeTransport.inboundMark + message])
    }

    /// Inbound lines reach the sink in arrival order.
    @Test("inbound lines reach the sink in arrival order")
    func inboundLinesReachTheSinkInArrivalOrder() async throws {
        let harness = TeeHarness()
        let messages = (1...Self.orderedMessageCount).map { #"{"id":\#($0)}"# }

        for message in messages {
            try await harness.agentSends(TeeBytes.line(message))
        }
        harness.agentStops()
        await harness.waitForEndOfStream()

        #expect(harness.teedLines == messages.map { FrameTeeTransport.inboundMark + $0 })
    }
}
