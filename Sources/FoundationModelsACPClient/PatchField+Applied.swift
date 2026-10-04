import FoundationModelsACP

// The one implementation of patch-field application in this package. The
// session list, the legacy session state, and the transcript entries all use
// it, so the patch rule has one place to change.

extension PatchField {
    /// Applies this patch state to a stored optional value: an omitted field
    /// keeps the stored value, `null` clears it, and a concrete value
    /// replaces it.
    ///
    /// - Parameter current: The stored value.
    /// - Returns: `current` for `.unchanged`, `nil` for `.cleared`, and the
    ///   new value for `.value`.
    func applied(to current: Wrapped?) -> Wrapped? {
        switch self {
        case .unchanged: current
        case .cleared: nil
        case .value(let value): value
        }
    }

    /// The value of a field that holds a concrete value, or `nil` for a field
    /// that is unchanged or cleared.
    ///
    /// The session merge engine folds each field, so on a merged value
    /// `.unchanged` means that no update gave the field, and `.cleared` means
    /// that the agent cleared it. A view shows both as no value. This is the
    /// patch applied to no stored value.
    var currentValue: Wrapped? {
        applied(to: nil)
    }
}
