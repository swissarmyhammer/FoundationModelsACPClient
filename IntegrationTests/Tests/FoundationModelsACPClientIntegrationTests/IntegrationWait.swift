import FoundationModelsACP
import FoundationModelsACPClient
import Observation

/// The error of a wait that ended on its failure event before its condition
/// became true.
struct WaitEndedOnFailure: Error {}

/// Waits until a condition on observable state is true, or until its failure
/// event is true. It reads no clock and polls nothing: it tracks the
/// observable values that the two closures read.
///
/// - Parameters:
///   - condition: The condition to wait for.
///   - failure: The failure event, for example the close of the connection.
/// - Throws: ``WaitEndedOnFailure`` when the failure event came first.
@MainActor
func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    orFailWhen failure: @escaping @MainActor () -> Bool
) async throws {
    let ended: @MainActor () -> Bool = { condition() || failure() }
    while !ended() {
        await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = ended()
            } onChange: {
                changed.resume()
            }
        }
    }
    guard condition() else { throw WaitEndedOnFailure() }
}

/// The text of each agent message of a session, joined, in transcript order.
///
/// - Parameter session: The session model.
/// - Returns: The text.
@MainActor
func agentText(in session: SessionModel) -> String {
    session.transcript
        .flatMap { entry -> [ContentBlock] in
            guard case .agentMessage(let message) = entry else { return [] }
            return message.content
        }
        .compactMap { block -> String? in
            guard case .text(let content) = block else { return nil }
            return content.text
        }
        .joined()
}

/// Connects a new model over a transport and initializes it. When
/// `initialize` throws, the helper closes the connection first.
///
/// - Parameters:
///   - transport: The transport of the agent, for example the transport of an
///     agent process, or a wrapper of it.
///   - clientName: The client name that `initialize` gives.
/// - Returns: The connected model, after `initialize`.
/// - Throws: The error of `initialize`.
@MainActor
func connectedModel(over transport: any ACPTransport, clientName: String) async throws -> ConnectionModel {
    let model = ConnectionModel(coalescingCadence: .zero)
    _ = await model.connect(over: transport)
    do {
        _ = try await model.initialize(.integrationTest(clientName: clientName))
    } catch {
        await model.disconnect()
        throw error
    }
    return model
}
