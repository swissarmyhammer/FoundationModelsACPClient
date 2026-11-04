import FoundationModelsACP
import FoundationModelsACPClient
import Observation
import Synchronization

/// The error of a wait that ended on its failure event before its condition
/// became true.
struct WaitEndedOnFailure: Error, CustomStringConvertible {
    /// The place of the wait call that ended.
    let location: String

    var description: String { "the wait at \(location) ended on its failure event" }
}

/// Waits until a condition on observable state is true, or until its failure
/// event is true, or until the task is cancelled. It reads no clock and polls
/// nothing: it tracks the observable values that the two closures read. A
/// test time limit cancels the task, and so ends a wait that cannot succeed.
///
/// - Parameters:
///   - condition: The condition to wait for.
///   - failure: The failure event, for example the close of the connection.
/// - Throws: ``WaitEndedOnFailure`` when the failure event came first, or
///   `CancellationError` when the task was cancelled.
@MainActor
func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    orFailWhen failure: @escaping @MainActor () -> Bool,
    fileID: String = #fileID,
    line: Int = #line
) async throws {
    let ended: @MainActor () -> Bool = { condition() || failure() }
    while !ended() {
        try Task.checkCancellation()
        let wake = OneShotWake()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
                wake.install(changed)
                withObservationTracking {
                    _ = ended()
                } onChange: {
                    wake.fire()
                }
            }
        } onCancel: {
            wake.fire()
        }
    }
    guard condition() else { throw WaitEndedOnFailure(location: "\(fileID):\(line)") }
}

/// A continuation that resumes at most one time, from any thread, whether the
/// fire call comes before or after the install call.
private final class OneShotWake: Sendable {
    private enum State {
        case idle
        case fired
        case waiting(CheckedContinuation<Void, Never>)
        case done
    }

    private let state = Mutex<State>(.idle)

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { state -> Bool in
            if case .fired = state {
                state = .done
                return true
            }
            state = .waiting(continuation)
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func fire() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            switch state {
            case .waiting(let continuation):
                state = .done
                return continuation
            case .idle:
                state = .fired
                return nil
            case .fired, .done:
                return nil
            }
        }
        continuation?.resume()
    }
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

/// The `agents` tool calls of a session, in transcript order.
///
/// - Parameter session: The session model.
/// - Returns: The tool call entries named `agents`.
@MainActor
func agentsCalls(in session: SessionModel) -> [ToolCallEntry] {
    session.transcript.compactMap { entry -> ToolCallEntry? in
        if case .toolCall(let call) = entry, call.name == "agents" { call } else { nil }
    }
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
