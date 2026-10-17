import Foundation
import FoundationModelsExtras

// The typed validation issue of a pending form elicitation. The type is the
// one of this package, not of FoundationModelsExtras, so a UI that does not
// import Extras can switch on the kind of the issue and show its own localized
// text. Each case maps one-to-one to a case of ``ElicitationValidationIssue``.

extension PendingElicitation {
    /// Why an answer is not valid against the requested schema of a form
    /// elicitation, as data that a UI can localize.
    ///
    /// ``PendingElicitation/validationIssue(of:)`` gives this value.
    /// ``PendingElicitation/validationFailure(of:)`` gives ``failureText``, the
    /// English sentence of the same issue.
    public struct ValidationIssue: Sendable, Equatable {
        /// The type of value that a field takes.
        public enum ExpectedValue: Sendable, Equatable {
            /// A string: a string property or a single select.
            case string

            /// A finite number.
            case number

            /// A finite whole number: a number property of type `integer`.
            case wholeNumber

            /// `true` or `false`.
            case boolean

            /// A list of strings: a multi select.
            case stringList
        }

        /// The `format` of a string field.
        public enum StringFormat: Sendable, Equatable {
            /// An email address.
            case email

            /// A URI.
            case uri

            /// A date, as `yyyy-MM-dd`.
            case date

            /// A date and a time, as ISO 8601.
            case dateTime
        }

        /// The rule that the answer breaks, with the limit of that rule.
        public enum Kind: Sendable, Equatable {
            /// The field is required, and the answer does not give it.
            case requiredFieldMissing

            /// The answer gives a key that is not a property of the schema.
            case fieldNotInSchema

            /// The value is not of the type that the field takes.
            case wrongType(expected: ExpectedValue)

            /// The string has fewer Unicode code points than `minLength`.
            case tooShort(minLength: Int)

            /// The string has more Unicode code points than `maxLength`.
            case tooLong(maxLength: Int)

            /// The string does not match `pattern`.
            case patternMismatch(pattern: String)

            /// `pattern` does not compile. This is a fault of the schema, not
            /// of the answer.
            case invalidPattern(pattern: String)

            /// The string does not have the `format` of the field.
            case invalidFormat(StringFormat)

            /// The number is less than `minimum`.
            case belowMinimum(Double)

            /// The number is more than `maximum`.
            case aboveMaximum(Double)

            /// The value of a single select is not one of its values.
            case valueNotAllowed(allowed: [String])

            /// An item of a multi select is not one of its values. `value` is
            /// the first such item.
            case itemNotAllowed(value: String, allowed: [String])

            /// The multi select has fewer items than `minItems`.
            case tooFewItems(minItems: Int)

            /// The multi select has more items than `maxItems`.
            case tooManyItems(maxItems: Int)
        }

        /// The name of the field that failed, or `nil` when the issue is about
        /// the whole answer.
        public let field: String?

        /// The rule that the answer breaks.
        public let kind: Kind

        /// Makes an issue.
        ///
        /// - Parameters:
        ///   - field: The name of the field that failed, or `nil` for the
        ///     whole answer.
        ///   - kind: The rule that the answer breaks.
        public init(field: String?, kind: Kind) {
            self.field = field
            self.kind = kind
        }

        /// The English sentence of this issue, as
        /// ``PendingElicitation/validationFailure(of:)`` gives it.
        ///
        /// The text is the one of FoundationModelsExtras. A UI that shows
        /// localized text uses ``field`` and ``kind`` instead.
        public var failureText: String {
            extrasIssue.failureText
        }
    }
}

// MARK: - The map to and from the Extras issue

extension PendingElicitation.ValidationIssue {
    /// Makes the issue of this package from the issue of Extras.
    ///
    /// - Parameter issue: The issue that Extras gives.
    init(_ issue: ElicitationValidationIssue) {
        self.init(field: issue.field, kind: Kind(issue.kind))
    }

    /// The Extras issue with the same field and the same kind.
    var extrasIssue: ElicitationValidationIssue {
        ElicitationValidationIssue(field: field, kind: kind.extrasKind)
    }
}

extension PendingElicitation.ValidationIssue.Kind {
    /// Makes the kind of this package from the kind of Extras.
    ///
    /// - Parameter kind: The kind that Extras gives.
    init(_ kind: ElicitationValidationIssue.Kind) {
        switch kind {
        case .requiredFieldMissing: self = .requiredFieldMissing
        case .fieldNotInSchema: self = .fieldNotInSchema
        case .wrongType(let expected): self = .wrongType(expected: .init(expected))
        case .tooShort(let minLength): self = .tooShort(minLength: minLength)
        case .tooLong(let maxLength): self = .tooLong(maxLength: maxLength)
        case .patternMismatch(let pattern): self = .patternMismatch(pattern: pattern)
        case .invalidPattern(let pattern): self = .invalidPattern(pattern: pattern)
        case .invalidFormat(let format): self = .invalidFormat(.init(format))
        case .belowMinimum(let minimum): self = .belowMinimum(minimum)
        case .aboveMaximum(let maximum): self = .aboveMaximum(maximum)
        case .valueNotAllowed(let allowed): self = .valueNotAllowed(allowed: allowed)
        case .itemNotAllowed(let value, let allowed): self = .itemNotAllowed(value: value, allowed: allowed)
        case .tooFewItems(let minItems): self = .tooFewItems(minItems: minItems)
        case .tooManyItems(let maxItems): self = .tooManyItems(maxItems: maxItems)
        }
    }

    /// The Extras kind with the same rule and the same limit.
    var extrasKind: ElicitationValidationIssue.Kind {
        switch self {
        case .requiredFieldMissing: .requiredFieldMissing
        case .fieldNotInSchema: .fieldNotInSchema
        case .wrongType(let expected): .wrongType(expected: expected.extrasValue)
        case .tooShort(let minLength): .tooShort(minLength: minLength)
        case .tooLong(let maxLength): .tooLong(maxLength: maxLength)
        case .patternMismatch(let pattern): .patternMismatch(pattern: pattern)
        case .invalidPattern(let pattern): .invalidPattern(pattern: pattern)
        case .invalidFormat(let format): .invalidFormat(format.extrasFormat)
        case .belowMinimum(let minimum): .belowMinimum(minimum)
        case .aboveMaximum(let maximum): .aboveMaximum(maximum)
        case .valueNotAllowed(let allowed): .valueNotAllowed(allowed: allowed)
        case .itemNotAllowed(let value, let allowed): .itemNotAllowed(value: value, allowed: allowed)
        case .tooFewItems(let minItems): .tooFewItems(minItems: minItems)
        case .tooManyItems(let maxItems): .tooManyItems(maxItems: maxItems)
        }
    }
}

extension PendingElicitation.ValidationIssue.ExpectedValue {
    /// Makes the expected value of this package from the one of Extras.
    ///
    /// - Parameter expected: The expected value that Extras gives.
    init(_ expected: ElicitationValidationIssue.ExpectedValue) {
        switch expected {
        case .string: self = .string
        case .number: self = .number
        case .wholeNumber: self = .wholeNumber
        case .boolean: self = .boolean
        case .stringList: self = .stringList
        }
    }

    /// The Extras expected value with the same type.
    var extrasValue: ElicitationValidationIssue.ExpectedValue {
        switch self {
        case .string: .string
        case .number: .number
        case .wholeNumber: .wholeNumber
        case .boolean: .boolean
        case .stringList: .stringList
        }
    }
}

extension PendingElicitation.ValidationIssue.StringFormat {
    /// Makes the format of this package from the one of Extras.
    ///
    /// - Parameter format: The format that Extras gives.
    init(_ format: ElicitationStringFormat) {
        switch format {
        case .email: self = .email
        case .uri: self = .uri
        case .date: self = .date
        case .dateTime: self = .dateTime
        }
    }

    /// The Extras format with the same rule.
    var extrasFormat: ElicitationStringFormat {
        switch self {
        case .email: .email
        case .uri: .uri
        case .date: .date
        case .dateTime: .dateTime
        }
    }
}
