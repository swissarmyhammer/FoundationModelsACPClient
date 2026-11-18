import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPClient

// The tests of `SessionModel.exportFileName` and `SessionModel.exportFolder`:
// the default name and the default folder of a Markdown export (D202). The
// name is the D199 slug of the title, so the slug cases are the cases of the
// `SessionSlug` tests of FoundationModelsExtras.

/// The text of a ULID that is the session id of the short id tests.
private let knownULIDText = "01M7QEQ0JBJDRCNK00P3M450TV"

/// The file name that the short id of ``knownULIDText`` gives: its last
/// seven characters, in lower case, then `.md`.
private let knownShortIDFileName = "3m450tv.md"

/// The working directory that the folder tests give the model.
private let workingDirectory = "/work/project"

/// The tests of the default name and the default folder of a Markdown export.
@MainActor
@Suite
struct SessionModelExportTests {
    /// Makes a model for the session with the given id.
    ///
    /// - Parameter sessionId: The id of the session of the model.
    /// - Returns: The model.
    func model(sessionId: SessionId = testSession) -> SessionModel {
        SessionModel(sessionId: sessionId, requestSender: FakeSessionRequestSender(), coalescingCadence: .zero)
    }

    /// Makes a model for the session with ``knownULIDText`` as its id.
    ///
    /// - Returns: The model.
    func knownULIDModel() -> SessionModel {
        model(sessionId: SessionId(rawValue: knownULIDText))
    }

    /// Makes the update that sets the title of the session.
    ///
    /// - Parameter title: The new title.
    /// - Returns: The update.
    func titleUpdate(_ title: String) -> SessionUpdate {
        .sessionInfoUpdate(SessionInfoUpdate(title: .value(title)))
    }

    /// Makes a directory summary of the session with ``knownULIDText`` as its
    /// id, so a test can read the short id that FoundationModelsExtras gives.
    ///
    /// - Returns: The summary.
    func knownULIDSummary() throws -> SessionSummary {
        let date = Date(timeIntervalSince1970: 0)
        return SessionSummary(
            id: try #require(.init(ulidString: knownULIDText)),
            agentID: "default",
            workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
            tags: [],
            kind: .root,
            state: .idle,
            origin: .client,
            createdAt: date,
            updatedAt: date,
            isLive: false
        )
    }

    @Test(arguments: [
        ("Fix the API tests", "fix-the-api-tests.md"),
        ("  --Hello__World!! ", "hello-world.md"),
        ("Café Ünïcode", "café-ünïcode.md"),
    ])
    func theNameIsTheSlugOfTheTitle(title: String, fileName: String) {
        let model = model()

        model.apply(titleUpdate(title))

        #expect(model.exportFileName == fileName)
    }

    @Test func aTitleWithAnEmptySlugGivesTheShortID() {
        let model = knownULIDModel()

        model.apply(titleUpdate("!!!"))

        #expect(model.exportFileName == knownShortIDFileName)
    }

    @Test func noTitleGivesTheShortID() {
        #expect(knownULIDModel().exportFileName == knownShortIDFileName)
    }

    @Test func theShortIDIsTheShortIDOfTheSessionSummary() throws {
        let summary = try knownULIDSummary()

        #expect(knownULIDModel().exportFileName == "\(summary.shortID).md")
    }

    @Test func aNewTitleChangesTheName() {
        let model = model()
        model.apply(titleUpdate("First name"))

        model.apply(titleUpdate("Second name"))

        #expect(model.exportFileName == "second-name.md")
    }

    @Test func theFolderIsTheURLOfTheWorkingDirectory() {
        let model = model()

        model.cwd = AbsolutePath(rawValue: workingDirectory)

        #expect(model.exportFolder == URL(fileURLWithPath: workingDirectory, isDirectory: true))
    }

    @Test func noWorkingDirectoryGivesNoFolder() {
        #expect(model().exportFolder == nil)
    }
}
