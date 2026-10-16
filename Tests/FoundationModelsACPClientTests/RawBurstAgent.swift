import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

/// An agent that writes raw NDJSON frames on the agent end of an in-memory
/// pair. It answers `initialize` and `session/new` (with ``testSession``).
/// After the `session/new` answer, it writes the frames of ``burst`` in ONE
/// transport write. The agent ignores the answers of the client to its own
/// requests.
///
/// The frames are raw JSON text, so a test controls each byte that the client
/// reads, for example a `_meta` member that the wire types do not model.
final class RawBurstAgent: Sendable {
    /// The agent end of the pair.
    private let transport: InMemoryTransport

    /// The frames that the agent writes in one write after the `session/new`
    /// answer.
    private let burst: Data

    /// Makes the agent.
    ///
    /// - Parameters:
    ///   - transport: The agent end of the pair.
    ///   - burst: The frames to write in one write after the `session/new`
    ///     answer. Make each frame with ``frame(_:)`` or ``request(id:method:params:)``.
    init(transport: InMemoryTransport, burst: Data) {
        self.transport = transport
        self.burst = burst
    }

    /// Connects a model to a new agent, initializes the connection, and opens
    /// the test session.
    ///
    /// - Parameter burst: The frames that the agent writes after the
    ///   `session/new` answer.
    /// - Returns: The model, the session model, and the task of the agent.
    ///   Cancel the task, and disconnect the model, at the end of the test.
    /// - Throws: The error of `initialize` or of `session/new`.
    @MainActor
    static func connect(
        burst: Data
    ) async throws -> (model: ConnectionModel, session: SessionModel, agentRun: Task<Void, any Error>) {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = RawBurstAgent(transport: agentEnd, burst: burst)
        let agentRun = Task { try await agent.run() }
        let model = ConnectionModel(coalescingCadence: .zero)
        _ = await model.connect(over: clientEnd)
        _ = try await model.initialize(makeInitializeRequest())
        let session = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: "/")))
        return (model, session, agentRun)
    }

    /// Reads the frames of the client until the stream ends, and answers
    /// them. On an error, the agent closes its end, so each request of the
    /// client fails with a closed connection and the test does not wait for
    /// ever.
    ///
    /// - Throws: The error that stopped the agent.
    func run() async throws {
        do {
            var buffer = Data()
            for try await chunk in transport.bytes {
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<end]
                    buffer.removeSubrange(buffer.startIndex...end)
                    try await answer(line)
                }
            }
        } catch {
            transport.close()
            throw error
        }
    }

    /// Answers one frame of the client.
    ///
    /// - Parameter line: The JSON text of the frame.
    private func answer(_ line: Data) async throws {
        guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        switch frame["method"] as? String {
        case ClientRequestSpan.Method.initialize?:
            let params = try JSONSerialization.data(withJSONObject: frame["params"] ?? [:])
            let request = try JSONDecoder().decode(InitializeRequest.self, from: params)
            let response = InitializeResponse(
                info: Implementation(name: "raw-burst-agent", version: "1.0.0"),
                protocolVersion: request.protocolVersion,
                capabilities: AgentCapabilities()
            )
            try await transport.write(Self.frame(["jsonrpc": "2.0", "id": frame["id"]!, "result": Self.json(response)]))
        case ClientRequestSpan.Method.newSession?:
            let response = try Self.json(NewSessionResponse(sessionId: testSession))
            try await transport.write(Self.frame(["jsonrpc": "2.0", "id": frame["id"]!, "result": response]))
            try await transport.write(burst)
        default:
            break
        }
    }

    /// Gives one request frame whose params are a wire value.
    ///
    /// - Parameters:
    ///   - id: The wire id of the request.
    ///   - method: The method of the request.
    ///   - params: The params of the request.
    /// - Returns: The JSON text and the newline.
    /// - Throws: The error of the encoder.
    static func request(id: String, method: String, params: some Encodable) throws -> Data {
        frame(["jsonrpc": "2.0", "id": id, "method": method, "params": try json(params)])
    }

    /// Gives a wire value as a JSON object.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The JSON object.
    /// - Throws: The error of the encoder.
    static func json(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    /// Gives one NDJSON frame.
    ///
    /// - Parameter object: The JSON object of the frame.
    /// - Returns: The JSON text and the newline.
    static func frame(_ object: [String: Any]) -> Data {
        // The objects here hold only JSON values, so the encode cannot fail.
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)
    }
}
