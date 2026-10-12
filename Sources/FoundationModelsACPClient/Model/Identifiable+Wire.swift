import FoundationModelsACP

// The `Identifiable` conformances of the wire types that the lists of the
// public model hold, so a SwiftUI view can use `ForEach(list)` and
// `List(list)` with no `id:` key path.
//
// Why these conformances are here and not in FoundationModelsACP: the types
// are generated code of FoundationModelsACP, and its generator does not add
// `Identifiable`. A conformance there needs a change to the generator, new
// generated code, and a new revision of that package. Thus this package adds
// the conformances, and `@retroactive` tells the compiler that a conformance
// of a type from another module to a protocol from another module is
// intentional. When FoundationModelsACP adds one of these conformances, the
// compiler reports two conformances: then remove that extension from this
// file.
//
// The model keeps one element for each id in each of its lists, so an id
// identifies one element. See `Array.keepingLastOfEachID(in:warningTo:)`.

extension SessionInfo: @retroactive Identifiable {
    /// The id of the session.
    public var id: SessionId {
        sessionId
    }
}

extension AvailableCommand: @retroactive Identifiable {
    /// The name of the command. The agent gives each command a unique name.
    public var id: String {
        name
    }
}

extension SessionConfigOption: @retroactive Identifiable {
    /// The id of the configuration option.
    public var id: SessionConfigId {
        configId
    }
}

extension AuthMethod: @retroactive Identifiable {
    /// The method id of the auth method.
    ///
    /// For a method of a type that this schema revision does not know, the
    /// id is the string `methodId` member of the payload: the ACP schema
    /// requires that member for each auth method. A malformed method with no
    /// such member has its `type` value as its id, so its id is stable.
    public var id: AuthMethodId {
        switch self {
        case .agent(let method):
            method.methodId
        case .terminal(let method):
            method.methodId
        case .unknown(let type, let payload):
            AuthMethodId(rawValue: payload.stringMember(Self.methodIdMember) ?? type)
        }
    }

    /// The name of the member that holds the method id in the payload of an
    /// auth method.
    private static let methodIdMember = "methodId"
}
