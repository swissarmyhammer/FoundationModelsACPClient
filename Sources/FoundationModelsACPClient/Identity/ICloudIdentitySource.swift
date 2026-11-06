#if canImport(CloudKit)
import CloudKit
import FoundationModelsExtras

/// Gives the identity of the person from the iCloud account of the Mac.
///
/// CAUTION: `CKContainer` stops the process when the process has no iCloud
/// entitlement. Thus the library never uses this source by default. Only an
/// app with the iCloud entitlement gives this source to ``ConnectionModel``.
///
/// When the account status is `.available` and the user record id has a
/// name, the actor id is the record name, the actor name is the full user
/// name, and the aliases hold the local id. In all other cases (an error, a
/// status that is not `.available`, or an empty record name), the source
/// gives the actor of ``LocalUserIdentitySource``, with no error and no
/// prompt.
public struct ICloudIdentitySource: PersonIdentitySource {
    /// Gives the iCloud account status.
    typealias AccountStatus = @Sendable () async throws -> CKAccountStatus

    /// Gives the record name of the iCloud user record id.
    typealias UserRecordName = @Sendable () async throws -> String

    /// The identifier of the iCloud container, for example
    /// `"iCloud.testudo.app"`.
    public let containerIdentifier: String

    /// The source of the fallback identity, and of the name and the alias of
    /// the iCloud actor.
    let local: LocalUserIdentitySource

    /// Gives the iCloud account status.
    private let accountStatus: AccountStatus

    /// Gives the record name of the iCloud user record id.
    private let userRecordName: UserRecordName

    /// Makes a source for an iCloud container.
    ///
    /// The source makes the `CKContainer` only when ``resolve()`` runs, so
    /// this initializer does not touch CloudKit.
    ///
    /// - Parameter containerIdentifier: The identifier of the iCloud
    ///   container of the app.
    public init(containerIdentifier: String) {
        self.init(
            containerIdentifier: containerIdentifier,
            local: LocalUserIdentitySource(),
            accountStatus: { try await CKContainer(identifier: containerIdentifier).accountStatus() },
            userRecordName: { try await CKContainer(identifier: containerIdentifier).userRecordID().recordName }
        )
    }

    /// Makes a source with injected CloudKit calls. The tests use this
    /// initializer, so they never touch `CKContainer`.
    ///
    /// - Parameters:
    ///   - containerIdentifier: The identifier of the iCloud container.
    ///   - local: The source of the fallback identity.
    ///   - accountStatus: Gives the iCloud account status.
    ///   - userRecordName: Gives the record name of the user record id.
    init(
        containerIdentifier: String,
        local: LocalUserIdentitySource,
        accountStatus: @escaping AccountStatus,
        userRecordName: @escaping UserRecordName
    ) {
        self.containerIdentifier = containerIdentifier
        self.local = local
        self.accountStatus = accountStatus
        self.userRecordName = userRecordName
    }

    /// Gives the iCloud actor, or the local actor when iCloud cannot give an
    /// identity.
    ///
    /// - Returns: The actor of the person.
    public func resolve() async -> GraphQLActor {
        let fallback = local.actor
        guard (try? await accountStatus()) == .available,
            let recordName = try? await userRecordName(),
            !recordName.isEmpty
        else {
            return fallback
        }
        return GraphQLActor(id: recordName, name: fallback.name, aliases: [fallback.id])
    }
}
#endif
