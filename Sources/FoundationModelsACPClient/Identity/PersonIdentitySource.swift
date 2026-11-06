import Foundation
import FoundationModelsExtras

/// Gives the identity of the person that runs the client.
///
/// ``ConnectionModel/initialize(_:)`` calls ``resolve()`` one time for each
/// `initialize`, and sends the actor in the `_meta` of the request, under
/// `GraphQLActor.initializeMetaKey`. The agent accepts the claim only from a
/// user-device connection, and puts it into each GraphQL viewer. Thus the
/// agent can tell the edits of the person from the edits of the agent.
///
/// ``LocalUserIdentitySource`` is the default source of ``ConnectionModel``.
/// An app with the iCloud entitlement can give an `ICloudIdentitySource`.
public protocol PersonIdentitySource: Sendable {
    /// Gives the actor of the person.
    ///
    /// A source must not throw and must not show a prompt. When a source
    /// cannot get its identity, it gives a fallback identity.
    ///
    /// - Returns: The actor of the person.
    func resolve() async -> GraphQLActor
}

/// Gives the identity of the local user of the Mac.
///
/// The id is `local/<user name>` and the name is the full user name. This
/// source needs no entitlement and does no I/O, so it is the default source
/// of ``ConnectionModel``. A command-line tool and the tests use it.
public struct LocalUserIdentitySource: PersonIdentitySource {
    /// The prefix of the id of a local user.
    public static let idPrefix = "local/"

    /// The short user name, for example the value of `NSUserName()`.
    public let userName: String

    /// The full user name, for example the value of `NSFullUserName()`.
    public let fullUserName: String

    /// Makes a source for a local user.
    ///
    /// - Parameters:
    ///   - userName: The short user name. The default is `NSUserName()`.
    ///   - fullUserName: The full user name. The default is
    ///     `NSFullUserName()`.
    public init(userName: String = NSUserName(), fullUserName: String = NSFullUserName()) {
        self.userName = userName
        self.fullUserName = fullUserName
    }

    /// The actor of the local user, with no aliases.
    public var actor: GraphQLActor {
        GraphQLActor(id: Self.idPrefix + userName, name: fullUserName)
    }

    /// Gives the actor of the local user.
    ///
    /// - Returns: ``actor``.
    public func resolve() async -> GraphQLActor {
        actor
    }
}
