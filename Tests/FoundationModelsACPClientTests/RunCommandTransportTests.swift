import Foundation
import FoundationModelsACP
import Testing

@testable import acp_client

// These tests cover the one decision `--frames` asks `RunCommand` to make: does
// the transport the run hands `AgentSession` carry a tee, or is it the agent's
// own stdio unchanged?
//
// `FrameTeeTransportTests` covers the tee itself — the line splitting, the
// direction marks, the incomplete tail. Nothing of that is repeated here. What
// is here is the wiring: the flag decides, and `--quiet` does not.
//
// No test spawns a process. The seam takes a transport, so an in-memory pair
// stands where the agent's stdio stands in a real run, and the row that puts
// `--frames` on a real exchange belongs to the nested `IntegrationTests`
// package.
//
// Both packages export a type called `TerminalOutput`, and this file imports
// both, so the binary's terminal layer is named `acp_client.TerminalOutput` in
// full. The wire package's `TerminalOutput` is the ACP model of an agent-owned
// terminal, and it has no part in these tests.

/// The ndJSON message these tests send from the client to the agent.
private let outboundMessage = #"{"id":1,"jsonrpc":"2.0","method":"initialize"}"#

/// The ndJSON message these tests send from the agent to the client.
private let inboundMessage = #"{"id":1,"jsonrpc":"2.0","result":{}}"#

/// Renders one ndJSON message as the line the wire carries.
///
/// - Parameter message: The message text, without a terminator.
/// - Returns: The message and one newline, as bytes.
private func line(_ message: String) -> Data {
    Data((message + "\n").utf8)
}

/// The line a teed message stands as in the buffer that receives standard
/// error, terminator included.
///
/// - Parameters:
///   - message: The message text, without a terminator.
///   - mark: The direction mark the tee puts before it.
/// - Returns: The whole line the terminal layer wrote.
private func teedLine(_ message: String, mark: String) -> String {
    mark + message + "\n"
}

/// One wiring of `RunCommand`'s transport decision: the agent end of the pair,
/// the transport the run would hand ``AgentSession``, and the buffer that
/// stands for standard error.
private struct WiredTransport {
    /// The end of the pair that stands for the agent's stdio.
    let agentEnd: InMemoryTransport

    /// The value under test.
    let transport: any ACPTransport

    /// Everything the terminal layer wrote, in the chunks the sink received.
    let buffer: ThreadSafeBuffer<String>

    /// Wires one transport the way `RunCommand` wires it.
    ///
    /// The injected terminal reading is always `false`: a test process cannot
    /// make its own standard error a terminal, and `--frames` writes its lines
    /// whether or not that descriptor is one.
    ///
    /// - Parameters:
    ///   - frames: Whether the command line carried `--frames`.
    ///   - verbosity: The verbosity to build the terminal layer with.
    init(frames: Bool, verbosity: TerminalVerbosity = .normal) {
        let (clientEnd, agent) = InMemoryTransport.pair()
        let captured = ThreadSafeBuffer<String>()
        agentEnd = agent
        buffer = captured
        transport = RunCommand.sessionTransport(
            over: clientEnd,
            frames: frames,
            terminal: acp_client.TerminalOutput(
                verbosity: verbosity,
                isStandardErrorATerminal: { false },
                sink: { captured.append($0) }
            )
        )
    }

    /// Sends one message in each direction, and returns once both have
    /// crossed.
    ///
    /// The wait needs no polling. The tee copies an outbound line to the sink
    /// before ``FrameTeeTransport/write(_:)`` returns, and an inbound line
    /// before it yields the chunk that carried it, so a chunk read off
    /// ``transport`` is proof that both sink calls already happened — or that
    /// there is no tee to make them.
    ///
    /// - Throws: The in-memory transport's write failure, or its stream
    ///   failure.
    func exchangeOneMessageEachWay() async throws {
        var chunks = transport.bytes.makeAsyncIterator()
        try await transport.write(line(outboundMessage))
        try await agentEnd.write(line(inboundMessage))
        _ = try await chunks.next()
    }
}

@Suite("acp-client --frames wiring")
struct RunCommandTransportTests {
    /// With no `--frames`, the run hands ``AgentSession`` the agent's own
    /// transport, so the whole exchange crosses and standard error stays
    /// empty — which is the `cli-plan.md` §8 rule for a default run.
    @Test("without --frames the exchange reaches standard error not at all")
    func withoutTheFlagNothingReachesStandardError() async throws {
        let wired = WiredTransport(frames: false)

        try await wired.exchangeOneMessageEachWay()

        #expect(wired.buffer.elements.isEmpty, "stderr held \"\(wired.buffer.text)\"")
    }

    /// `--frames` writes every ndJSON message to standard error, in both
    /// directions, each under its own direction mark (§6.1).
    @Test("--frames tees both directions to standard error")
    func theFlagTeesBothDirections() async throws {
        let wired = WiredTransport(frames: true)

        try await wired.exchangeOneMessageEachWay()

        #expect(
            wired.buffer.elements == [
                teedLine(outboundMessage, mark: FrameTeeTransport.outboundMark),
                teedLine(inboundMessage, mark: FrameTeeTransport.inboundMark),
            ]
        )
    }

    /// `--frames` is a debugging switch and not a verbosity level, so
    /// `--quiet` does not silence it.
    @Test("--frames writes at quiet too")
    func theFlagWritesAtQuietToo() async throws {
        let wired = WiredTransport(frames: true, verbosity: .quiet)

        try await wired.exchangeOneMessageEachWay()

        #expect(
            wired.buffer.text
                == teedLine(outboundMessage, mark: FrameTeeTransport.outboundMark)
                    + teedLine(inboundMessage, mark: FrameTeeTransport.inboundMark)
        )
    }
}
