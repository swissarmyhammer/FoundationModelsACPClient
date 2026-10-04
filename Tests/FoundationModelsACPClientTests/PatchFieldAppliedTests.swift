import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the one implementation of patch-field application. The session
// list, the legacy session state, and the transcript entries all use it.

/// The stored value that each test patches.
private let storedTitle = "Stored title"

/// The value that a `.value` patch gives.
private let patchedTitle = "Patched title"

@Suite("PatchField application")
struct PatchFieldAppliedTests {
    @Test(arguments: [
        (PatchField<String>.unchanged, storedTitle as String?),
        (PatchField<String>.cleared, nil),
        (PatchField<String>.value(patchedTitle), patchedTitle),
    ])
    func appliedToAStoredValueFollowsThePatchRule(patch: PatchField<String>, expected: String?) {
        #expect(patch.applied(to: storedTitle) == expected)
    }

    @Test(arguments: [
        (PatchField<String>.unchanged, nil as String?),
        (PatchField<String>.cleared, nil),
        (PatchField<String>.value(patchedTitle), patchedTitle),
    ])
    func currentValueIsTheValueOfAConcretePatchOnly(patch: PatchField<String>, expected: String?) {
        #expect(patch.currentValue == expected)
    }
}
