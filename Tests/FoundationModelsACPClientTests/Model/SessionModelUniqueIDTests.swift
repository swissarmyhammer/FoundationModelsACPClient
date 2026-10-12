import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the rule that keeps one element for each id in
// `SessionModel.availableCommands` and `SessionModel.configOptions`. The
// agent can send two elements with the same id; the model keeps the last one
// in the position of the first one, and logs one warning.

/// The fixtures of the unique-id tests of the session model.
private enum SessionUniqueIDFixtures {
    /// The name of the command that the agent sends two times.
    static let repeatedCommandName = "create_plan"

    /// The first copy of the repeated command.
    static let firstPlanCommand = AvailableCommand(description: "Makes a plan", name: repeatedCommandName)

    /// The last copy of the repeated command.
    static let lastPlanCommand = AvailableCommand(description: "Makes a better plan", name: repeatedCommandName)

    /// A command that the agent sends one time.
    static let researchCommand = AvailableCommand(description: "Reads the code", name: "research_codebase")

    /// The commands of one update, with the plan command two times.
    static let commandsWithRepeat = [firstPlanCommand, researchCommand, lastPlanCommand]

    /// The commands that the model keeps from ``commandsWithRepeat``.
    static let uniqueCommands = [lastPlanCommand, researchCommand]

    /// The id of the option that the agent sends two times.
    static let repeatedOptionId = SessionConfigId(rawValue: "mode")

    /// The first copy of the repeated option.
    static let firstModeOption = SessionConfigOption(
        configId: repeatedOptionId,
        name: "Mode",
        type: .boolean(SessionConfigBoolean(currentValue: true))
    )

    /// The last copy of the repeated option.
    static let lastModeOption = SessionConfigOption(
        configId: repeatedOptionId,
        name: "Mode",
        type: .boolean(SessionConfigBoolean(currentValue: false))
    )

    /// An option that the agent sends one time.
    static let modelOption = SessionConfigOption(
        configId: SessionConfigId(rawValue: "model"),
        name: "Model",
        type: .boolean(SessionConfigBoolean(currentValue: true))
    )

    /// The options of one update, with the mode option two times.
    static let optionsWithRepeat = [firstModeOption, modelOption, lastModeOption]

    /// The options that the model keeps from ``optionsWithRepeat``.
    static let uniqueOptions = [lastModeOption, modelOption]

    /// Makes a model that writes each log message into a buffer.
    ///
    /// - Parameter messages: The buffer that gets each log message.
    /// - Returns: The model.
    @MainActor
    static func model(loggingTo messages: ThreadSafeBuffer<String>) -> SessionModel {
        SessionModelFixtures.makeModel(sender: FakeSessionRequestSender(), logger: ACPLogger { messages.append($0) })
    }
}

/// The unique-id tests of the session model, in one suite so that
/// `swift test --filter SessionModelUniqueIDTests` selects them.
@MainActor
struct SessionModelUniqueIDTests {
    @Test func aRepeatedCommandInOneUpdateKeepsTheLastCopyAndLogsOneWarning() {
        let messages = ThreadSafeBuffer<String>()
        let model = SessionUniqueIDFixtures.model(loggingTo: messages)

        model.apply(.availableCommandsUpdate(AvailableCommandsUpdate(
            availableCommands: SessionUniqueIDFixtures.commandsWithRepeat
        )))

        #expect(model.availableCommands == SessionUniqueIDFixtures.uniqueCommands)
        #expect(messages.elements.count == 1)
        #expect(messages.elements.allSatisfy {
            $0.contains("SessionModel.availableCommands") && $0.contains(SessionUniqueIDFixtures.repeatedCommandName)
        })
    }

    @Test func aRepeatedConfigOptionInOneUpdateKeepsTheLastCopyAndLogsOneWarning() {
        let messages = ThreadSafeBuffer<String>()
        let model = SessionUniqueIDFixtures.model(loggingTo: messages)

        model.apply(.configOptionUpdate(ConfigOptionUpdate(configOptions: SessionUniqueIDFixtures.optionsWithRepeat)))

        #expect(model.configOptions == SessionUniqueIDFixtures.uniqueOptions)
        #expect(messages.elements.count == 1)
        #expect(messages.elements.allSatisfy {
            $0.contains("SessionModel.configOptions")
                && $0.contains(SessionUniqueIDFixtures.repeatedOptionId.rawValue)
        })
    }

    @Test func aSeedWithRepeatsKeepsOneElementForEachId() {
        let messages = ThreadSafeBuffer<String>()
        let model = SessionUniqueIDFixtures.model(loggingTo: messages)

        model.seed(
            availableCommands: SessionUniqueIDFixtures.commandsWithRepeat,
            configOptions: SessionUniqueIDFixtures.optionsWithRepeat
        )

        #expect(model.availableCommands == SessionUniqueIDFixtures.uniqueCommands)
        #expect(model.configOptions == SessionUniqueIDFixtures.uniqueOptions)
    }

    @Test func listsWithNoRepeatLogNothing() {
        let messages = ThreadSafeBuffer<String>()
        let model = SessionUniqueIDFixtures.model(loggingTo: messages)

        model.apply(.availableCommandsUpdate(AvailableCommandsUpdate(
            availableCommands: SessionUniqueIDFixtures.uniqueCommands
        )))
        model.apply(.configOptionUpdate(ConfigOptionUpdate(configOptions: SessionUniqueIDFixtures.uniqueOptions)))

        #expect(model.availableCommands == SessionUniqueIDFixtures.uniqueCommands)
        #expect(model.configOptions == SessionUniqueIDFixtures.uniqueOptions)
        #expect(messages.elements.isEmpty)
    }
}
