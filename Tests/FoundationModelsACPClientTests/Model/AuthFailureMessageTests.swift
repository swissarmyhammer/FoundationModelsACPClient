import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the text of `AuthFailure.Reason.message`. Each text comes from
// the string catalog of the client package, so a host can translate it. The
// English text of each reason must not change, because current callers and
// tests use it.

/// The fixtures of the auth failure message tests.
private enum AuthFailureMessageFixtures {
    /// The language code of the English localization of the string catalog.
    static let englishLanguage = "en"

    /// The value that a bundle gives when its string table has no entry for a
    /// key. No catalog text is equal to it.
    static let missingEntry = "<no catalog entry>"

    /// Each reason, with the English text that the reason gives.
    static let englishTexts: [(AuthFailure.Reason, String)] = [
        (.request(InitializeFixtures.loginRefusal), InitializeFixtures.loginRefusal.message),
        (
            .terminal(exitStatus: InitializeFixtures.failedExitStatus, message: InitializeFixtures.terminalMessage),
            InitializeFixtures.terminalMessage
        ),
        (
            .terminal(exitStatus: InitializeFixtures.failedExitStatus, message: nil),
            "The sign-in process stopped with exit status 1."
        ),
        (.terminal(exitStatus: nil, message: nil), "The sign-in process did not stop normally."),
        (
            .unsupported(method: ClientRequestSpan.Method.login),
            "The agent cannot do this authentication operation."
        ),
        (
            .unsupported(method: ConnectionModelError.terminalAuthOperation),
            "The agent cannot do this authentication operation."
        ),
    ]
}

@Suite struct AuthFailureMessageTests {
    @Test(arguments: AuthFailureMessageFixtures.englishTexts)
    func eachReasonGivesItsEnglishText(_ reason: AuthFailure.Reason, _ englishText: String) {
        #expect(reason.message == englishText)
    }

    @Test(arguments: AuthFailure.Reason.MessageKey.allCases)
    func eachMessageKeyHasAnEnglishCatalogEntry(_ key: AuthFailure.Reason.MessageKey) throws {
        let englishPath = try #require(
            AuthFailure.Reason.MessageKey.bundle.path(
                forResource: AuthFailureMessageFixtures.englishLanguage,
                ofType: "lproj"
            )
        )
        let english = try #require(Bundle(path: englishPath))

        let entry = english.localizedString(
            forKey: key.rawValue,
            value: AuthFailureMessageFixtures.missingEntry,
            table: nil
        )

        #expect(entry != AuthFailureMessageFixtures.missingEntry)
    }
}
