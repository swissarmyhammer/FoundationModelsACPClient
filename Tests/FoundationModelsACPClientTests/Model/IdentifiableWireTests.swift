import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the `Identifiable` conformances of the wire types that the
// lists of the public model hold, and of the list rule that keeps one
// element for each id.

/// The fixtures of the `Identifiable` tests.
private enum IdentifiableWireFixtures {
    /// The working directory of each test session.
    static let workingDirectory = AbsolutePath(rawValue: "/work")

    /// The id of the auth method of each auth method test.
    static let methodId = AuthMethodId(rawValue: "api-key")

    /// The `type` value of an auth method that this schema revision does
    /// not know.
    static let futureMethodType = "_future"

    /// An identified value for the list rule tests.
    struct Item: Identifiable, Equatable {
        /// The id of the item.
        let id: String

        /// A value that tells two items with the same id apart.
        let value: Int
    }

    /// The first value of an item.
    static let firstValue = 1

    /// The second value of an item.
    static let secondValue = 2

    /// The third value of an item.
    static let thirdValue = 3

    /// The id of the item that comes again.
    static let repeatedID = "a"

    /// The id of the item that comes one time.
    static let singleID = "b"
}

/// The `Identifiable` tests, in one suite so that
/// `swift test --filter IdentifiableWireTests` selects them.
struct IdentifiableWireTests {
    // MARK: - Conformances

    @Test func theIdOfASessionInfoIsItsSessionId() {
        let sessionId = SessionId(rawValue: "session-7")
        let info = SessionInfo(cwd: IdentifiableWireFixtures.workingDirectory, sessionId: sessionId)

        #expect(info.id == sessionId)
    }

    @Test func theIdOfAnAvailableCommandIsItsName() {
        let command = AvailableCommand(description: "Makes a plan", name: "create_plan")

        #expect(command.id == "create_plan")
    }

    @Test func theIdOfAConfigOptionIsItsConfigId() {
        let configId = SessionConfigId(rawValue: "mode")
        let option = SessionConfigOption(
            configId: configId,
            name: "Mode",
            type: .boolean(SessionConfigBoolean(currentValue: true))
        )

        #expect(option.id == configId)
    }

    @Test func theIdOfAnAgentAuthMethodIsItsMethodId() {
        let method = AuthMethod.agent(AuthMethodAgent(methodId: IdentifiableWireFixtures.methodId, name: "API key"))

        #expect(method.id == IdentifiableWireFixtures.methodId)
    }

    @Test func theIdOfATerminalAuthMethodIsItsMethodId() {
        let method = AuthMethod.terminal(
            AuthMethodTerminal(methodId: IdentifiableWireFixtures.methodId, name: "Terminal login")
        )

        #expect(method.id == IdentifiableWireFixtures.methodId)
    }

    @Test func theIdOfAnUnknownAuthMethodIsTheMethodIdMemberOfItsPayload() {
        let payload = JSONValue.object([
            "methodId": .string(IdentifiableWireFixtures.methodId.rawValue),
            "name": .string("Future login"),
        ])
        let method = AuthMethod.unknown(IdentifiableWireFixtures.futureMethodType, payload)

        #expect(method.id == IdentifiableWireFixtures.methodId)
    }

    @Test func theIdOfAnUnknownAuthMethodWithNoMethodIdIsItsType() {
        let method = AuthMethod.unknown(IdentifiableWireFixtures.futureMethodType, .object(["name": .string("Future")]))

        #expect(method.id == AuthMethodId(rawValue: IdentifiableWireFixtures.futureMethodType))
    }

    // MARK: - One element for each id

    @Test func aRepeatedIdKeepsTheLastElementInThePositionOfTheFirst() {
        typealias Item = IdentifiableWireFixtures.Item
        let repeatedID = IdentifiableWireFixtures.repeatedID
        let singleID = IdentifiableWireFixtures.singleID
        let elements = [
            Item(id: repeatedID, value: IdentifiableWireFixtures.firstValue),
            Item(id: singleID, value: IdentifiableWireFixtures.firstValue),
            Item(id: repeatedID, value: IdentifiableWireFixtures.secondValue),
            Item(id: repeatedID, value: IdentifiableWireFixtures.thirdValue),
        ]

        let unique = elements.keepingLastOfEachID()

        #expect(unique.elements == [
            Item(id: repeatedID, value: IdentifiableWireFixtures.thirdValue),
            Item(id: singleID, value: IdentifiableWireFixtures.firstValue),
        ])
        #expect(unique.repeatedIDs == [repeatedID])
    }

    @Test func aListWithNoRepeatedIdStaysTheSame() {
        typealias Item = IdentifiableWireFixtures.Item
        let elements = [
            Item(id: IdentifiableWireFixtures.repeatedID, value: IdentifiableWireFixtures.firstValue),
            Item(id: IdentifiableWireFixtures.singleID, value: IdentifiableWireFixtures.secondValue),
        ]

        let unique = elements.keepingLastOfEachID()

        #expect(unique.elements == elements)
        #expect(unique.repeatedIDs.isEmpty)
    }

    @Test func aRepeatedIdLogsOneWarningThatNamesTheListAndTheId() {
        typealias Item = IdentifiableWireFixtures.Item
        let messages = ThreadSafeBuffer<String>()
        let elements = [
            Item(id: IdentifiableWireFixtures.repeatedID, value: IdentifiableWireFixtures.firstValue),
            Item(id: IdentifiableWireFixtures.repeatedID, value: IdentifiableWireFixtures.secondValue),
            Item(id: IdentifiableWireFixtures.repeatedID, value: IdentifiableWireFixtures.thirdValue),
        ]

        let unique = elements.keepingLastOfEachID(in: "Test.items", warningTo: ACPLogger { messages.append($0) })

        #expect(unique == [Item(id: IdentifiableWireFixtures.repeatedID, value: IdentifiableWireFixtures.thirdValue)])
        #expect(messages.elements.count == 1)
        #expect(messages.elements.allSatisfy { $0.contains("Test.items") && $0.contains("\"a\"") })
    }

    @Test func aListWithNoRepeatedIdLogsNothing() {
        typealias Item = IdentifiableWireFixtures.Item
        let messages = ThreadSafeBuffer<String>()
        let elements = [Item(id: IdentifiableWireFixtures.singleID, value: IdentifiableWireFixtures.firstValue)]

        let unique = elements.keepingLastOfEachID(in: "Test.items", warningTo: ACPLogger { messages.append($0) })

        #expect(unique == elements)
        #expect(messages.elements.isEmpty)
    }
}
