import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPClient

// The tests of `PendingElicitation.validationFailure(of:)`: the bridge from the
// wire schema of a form elicitation to the check of FoundationModelsExtras. A
// valid answer gives `nil`, a field that breaks a rule gives the Extras text,
// and a schema or an answer that Extras cannot decode gives `nil`.

/// The validation bridge tests, in one suite so that `swift test --filter
/// PendingElicitationValidationTests` selects them.
@Suite
struct PendingElicitationValidationTests {
    /// The longest name that the test schema accepts.
    private let maxNameLength = 3

    /// Makes a pending form elicitation with one required "name" string.
    ///
    /// - Parameter nameProperty: The wire schema of the "name" property.
    /// - Returns: The pending elicitation.
    private func pendingForm(nameProperty: JSONValue) -> PendingElicitation {
        let schema = ElicitationSchema(properties: .object(["name": nameProperty]), required: ["name"])
        let request = CreateElicitationRequest(
            message: ElicitationFixtures.formMessage,
            mode: .form(ElicitationFormMode(requestedSchema: schema, scope: .session(ElicitationFixtures.sessionScope)))
        )
        return PendingElicitation(id: UUID(), request: request)
    }

    /// The pending form whose "name" has a maximum length.
    private var boundedNameForm: PendingElicitation {
        pendingForm(nameProperty: .object(["type": .string("string"), "maxLength": .number(Double(maxNameLength))]))
    }

    @Test func aValidAnswerGivesNil() {
        let failure = boundedNameForm.validationFailure(of: .object(["name": .string("ori")]))

        #expect(failure == nil)
    }

    @Test func aFieldThatBreaksARuleGivesTheExtrasText() {
        let answer: [String: ElicitationValue] = ["name": .string("orion")]
        let extrasSchema = ElicitationRequestedSchema(
            properties: ["name": .string(ElicitationStringSchema(maxLength: maxNameLength))],
            required: ["name"]
        )
        let expected = extrasSchema.validationFailure(of: answer)

        let failure = boundedNameForm.validationFailure(of: .object(["name": .string("orion")]))

        #expect(expected != nil)
        #expect(failure == expected)
    }

    @Test func aMissingRequiredFieldGivesTheExtrasText() {
        let failure = boundedNameForm.validationFailure(of: nil)

        #expect(failure?.contains("name") == true)
    }

    @Test func aSchemaThatExtrasCannotDecodeGivesNil() {
        // Extras decodes strictly: a property type outside the MCP subset
        // does not decode, so the bridge cannot check the answer.
        let form = pendingForm(nameProperty: .object(["type": .string("color")]))

        #expect(form.validationFailure(of: .object(["name": .string("orion")])) == nil)
    }

    @Test func anAnswerThatExtrasCannotDecodeGivesNil() {
        let failure = boundedNameForm.validationFailure(of: .object(["name": .object(["nested": .string("x")])]))

        #expect(failure == nil)
    }

    @Test func aUrlElicitationGivesNil() {
        let request = ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        let pending = PendingElicitation(id: UUID(), request: request)

        #expect(pending.validationFailure(of: nil) == nil)
    }
}
