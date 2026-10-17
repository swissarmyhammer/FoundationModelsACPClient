import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Logging

// The validation bridge of a pending form elicitation: the check of an answer
// against the requested schema, before the UI sends the answer. The check is
// the one of FoundationModelsExtras, so a UI that does not import Extras gets
// the same rules and the same failure text as a tool of the agent. The issue
// is a type of this package, so the UI can also show its own localized text.

extension PendingElicitation {
    /// Tells why `content` is not a valid answer to the requested schema of
    /// this form elicitation, as one English sentence.
    ///
    /// This is the ``ValidationIssue/failureText`` of
    /// ``validationIssue(of:)``, with the same rules and the same `nil`
    /// cases. A UI that shows localized text uses ``validationIssue(of:)``.
    ///
    /// - Parameter content: The form values that the UI is about to send with
    ///   ``SessionModel/acceptElicitation(_:content:)``, or `nil` for no
    ///   content.
    /// - Returns: `nil` when the answer is valid or cannot be checked, or one
    ///   sentence that names the first field that failed and the rule that it
    ///   broke.
    public func validationFailure(of content: JSONValue?) -> String? {
        validationIssue(of: content)?.failureText
    }

    /// Tells why `content` is not a valid answer to the requested schema of
    /// this form elicitation, as data that a UI can localize.
    ///
    /// The bridge decodes the wire schema of the request as the Extras
    /// ``ElicitationRequestedSchema`` (the reverse of the bridge in the
    /// elicitation relay of the agent), decodes `content` as Extras form
    /// values, and maps the result of
    /// ``ElicitationRequestedSchema/validationIssue(of:)`` to a
    /// ``ValidationIssue``.
    ///
    /// Extras decodes strictly. When the schema or the content does not
    /// decode, the bridge cannot check the answer: it gives `nil` and writes
    /// one log line, so the agent stays the final judge of the answer. A
    /// url-mode elicitation has no schema, so it gives `nil`.
    ///
    /// - Parameter content: The form values that the UI is about to send with
    ///   ``SessionModel/acceptElicitation(_:content:)``, or `nil` for no
    ///   content.
    /// - Returns: `nil` when the answer is valid or cannot be checked, or the
    ///   issue of the first field that failed, with the rule that it broke.
    public func validationIssue(of content: JSONValue?) -> ValidationIssue? {
        guard case .form(let form) = request.mode else { return nil }
        guard let schema = Self.decode(ElicitationRequestedSchema.self, from: form.requestedSchema) else {
            Self.logUncheckedAnswer("the requested schema does not decode as an Extras schema")
            return nil
        }
        let values: [String: ElicitationValue]?
        if let content {
            guard let decoded = Self.decode([String: ElicitationValue].self, from: content) else {
                Self.logUncheckedAnswer("the answer does not decode as Extras form values")
                return nil
            }
            values = decoded
        } else {
            values = nil
        }
        return schema.validationIssue(of: values).map(ValidationIssue.init)
    }

    /// Tells whether `text` has a match of the `pattern` rule of a form field.
    ///
    /// The bridge gives the result of
    /// ``ElicitationValidation/patternMatches(_:pattern:)`` of Extras, so a UI
    /// that does not import Extras checks a field while the user types with
    /// the same rule as ``validationFailure(of:)``. The check is an ECMA-262
    /// search with no flags, and it is not anchored.
    ///
    /// - Parameters:
    ///   - text: The value of the field.
    ///   - pattern: The `pattern` of the field schema.
    /// - Returns: `nil` when `pattern` does not compile, `true` when a match
    ///   is in `text`, and `false` when no match is in `text`.
    public static func patternMatches(_ text: String, pattern: String) -> Bool? {
        ElicitationValidation.patternMatches(text, pattern: pattern)
    }

    /// The length of `text` for the `minLength` and `maxLength` rules of a
    /// form field.
    ///
    /// The bridge gives the result of
    /// ``ElicitationValidation/codePointLength(_:)`` of Extras: the count of
    /// the Unicode code points of `text`, as JSON Schema counts it.
    ///
    /// - Parameter text: The value of the field.
    /// - Returns: The count of the Unicode code points of `text`.
    public static func codePointLength(_ text: String) -> Int {
        ElicitationValidation.codePointLength(text)
    }

    /// Decodes a value through its JSON encoding.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - value: The value to encode, for example a wire schema or a
    ///     ``JSONValue``.
    /// - Returns: The decoded value, or `nil` when the encode or the decode
    ///   fails.
    private static func decode<Decoded: Decodable>(_ type: Decoded.Type, from value: some Encodable) -> Decoded? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writes the log line of an answer that the bridge cannot check.
    ///
    /// - Parameter reason: Why the bridge cannot check the answer.
    private static func logUncheckedAnswer(_ reason: String) {
        Logger(label: ACPClientTelemetry.logLabel).warning(
            "The client cannot check the elicitation answer before it sends it: \(reason)."
        )
    }
}
