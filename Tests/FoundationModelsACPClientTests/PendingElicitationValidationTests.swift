import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPClient

// The tests of `PendingElicitation.validationFailure(of:)`: the bridge from the
// wire schema of a form elicitation to the check of FoundationModelsExtras. A
// valid answer gives `nil`, a field that breaks a rule gives the Extras text,
// and a schema or an answer that Extras cannot decode gives `nil`. The tests of
// `validationIssue(of:)` prove the same cases for the typed issue, and prove
// that each Extras kind maps to its kind of this package. The tests of
// `patternMatches(_:pattern:)` and `codePointLength(_:)` use the examples of
// AgentViewKit D-1.

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

    @Test func aFieldThatBreaksARuleGivesATypedIssue() {
        let issue = boundedNameForm.validationIssue(of: .object(["name": .string("orion")]))

        #expect(issue == PendingElicitation.ValidationIssue(field: "name", kind: .tooLong(maxLength: maxNameLength)))
    }

    @Test func theFailureTextIsTheTextOfTheIssue() {
        let content: JSONValue = .object(["name": .string("orion")])

        let issue = boundedNameForm.validationIssue(of: content)

        #expect(issue != nil)
        #expect(boundedNameForm.validationFailure(of: content) == issue?.failureText)
    }

    @Test func aMissingRequiredFieldGivesATypedIssue() {
        let issue = boundedNameForm.validationIssue(of: nil)

        #expect(issue == PendingElicitation.ValidationIssue(field: "name", kind: .requiredFieldMissing))
    }

    @Test func theIssueHasTheSameNilCasesAsTheFailureText() {
        let undecodableSchema = pendingForm(nameProperty: .object(["type": .string("color")]))
        let url = PendingElicitation(
            id: UUID(),
            request: ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        )

        #expect(boundedNameForm.validationIssue(of: .object(["name": .string("ori")])) == nil)
        #expect(undecodableSchema.validationIssue(of: .object(["name": .string("orion")])) == nil)
        #expect(boundedNameForm.validationIssue(of: .object(["name": .object(["nested": .string("x")])])) == nil)
        #expect(url.validationIssue(of: nil) == nil)
    }

    /// Each kind of the Extras issue, with the kind of this package that it
    /// maps to. The list has each case of each enum: each kind, each expected
    /// value and each string format.
    private static let kindPairs: [(ElicitationValidationIssue.Kind, PendingElicitation.ValidationIssue.Kind)] = [
        (.requiredFieldMissing, .requiredFieldMissing),
        (.fieldNotInSchema, .fieldNotInSchema),
        (.wrongType(expected: .string), .wrongType(expected: .string)),
        (.wrongType(expected: .number), .wrongType(expected: .number)),
        (.wrongType(expected: .wholeNumber), .wrongType(expected: .wholeNumber)),
        (.wrongType(expected: .boolean), .wrongType(expected: .boolean)),
        (.wrongType(expected: .stringList), .wrongType(expected: .stringList)),
        (.tooShort(minLength: 2), .tooShort(minLength: 2)),
        (.tooLong(maxLength: 3), .tooLong(maxLength: 3)),
        (.patternMismatch(pattern: "^[0-9]{5}$"), .patternMismatch(pattern: "^[0-9]{5}$")),
        (.invalidPattern(pattern: "["), .invalidPattern(pattern: "[")),
        (.invalidFormat(.email), .invalidFormat(.email)),
        (.invalidFormat(.uri), .invalidFormat(.uri)),
        (.invalidFormat(.date), .invalidFormat(.date)),
        (.invalidFormat(.dateTime), .invalidFormat(.dateTime)),
        (.belowMinimum(0.5), .belowMinimum(0.5)),
        (.aboveMaximum(150), .aboveMaximum(150)),
        (.valueNotAllowed(allowed: ["red", "green"]), .valueNotAllowed(allowed: ["red", "green"])),
        (.itemNotAllowed(value: "blue", allowed: ["red"]), .itemNotAllowed(value: "blue", allowed: ["red"])),
        (.tooFewItems(minItems: 1), .tooFewItems(minItems: 1)),
        (.tooManyItems(maxItems: 4), .tooManyItems(maxItems: 4)),
    ]

    @Test func eachExtrasKindMapsToItsKind() {
        for (extrasKind, kind) in Self.kindPairs {
            #expect(PendingElicitation.ValidationIssue.Kind(extrasKind) == kind)
            #expect(kind.extrasKind == extrasKind)
        }
    }

    @Test func eachIssueHasTheFailureTextOfExtras() {
        for (extrasKind, kind) in Self.kindPairs {
            for field in ["zip", nil] as [String?] {
                let extrasIssue = ElicitationValidationIssue(field: field, kind: extrasKind)

                let issue = PendingElicitation.ValidationIssue(extrasIssue)

                #expect(issue == PendingElicitation.ValidationIssue(field: field, kind: kind))
                #expect(issue.failureText == extrasIssue.failureText)
            }
        }
    }

    @Test func aPatternIsASearchThatIsNotAnchored() {
        #expect(PendingElicitation.patternMatches("zip 12345", pattern: "[0-9]{5}") == true)
    }

    @Test func aDigitClassMatchesOnlyASCIIDigits() {
        // ECMA-262 `\d` is [0-9]: the Arabic-Indic digit one does not match.
        #expect(PendingElicitation.patternMatches("\u{661}", pattern: "\\d") == false)
    }

    @Test func aPatternThatDoesNotCompileGivesNil() {
        #expect(PendingElicitation.patternMatches("x", pattern: "[") == nil)
    }

    @Test func theLengthIsTheCountOfCodePoints() {
        // "e" and a combining acute accent are one character but two code
        // points; the thumbs-up emoji is one code point.
        #expect(PendingElicitation.codePointLength("e\u{301}") == 2)
        #expect(PendingElicitation.codePointLength("👍") == 1)
    }
}
