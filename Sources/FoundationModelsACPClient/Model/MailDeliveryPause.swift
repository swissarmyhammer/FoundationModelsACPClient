import FoundationModelsACP

/// A pause of the mail delivery of a session, as the agent reported it in a
/// `_mail_delivery_paused` session update.
///
/// The FoundationModelsACPAgent session pauses the mail delivery when its
/// limit of answers in a row with no caller message is reached. The session
/// then holds the results of its runs, and it starts no answer for them until
/// the next caller message. The next `session/prompt` carries the held mail
/// into its answer, so that prompt lifts the pause. The agent sends no update
/// for the lift.
///
/// ``SessionModel/mailDeliveryPause`` holds the last pause. It is the payload
/// of the agent, not a busy state: ``heldMail`` is the list of the held
/// results, so a UI can show them and tell the user that the next message
/// gives them to the agent.
public struct MailDeliveryPause: Hashable, Sendable {
    /// The limit in force: the most answers in a row that run mail alone
    /// starts.
    public let limit: Int

    /// How many run results the session holds, as the agent sent it.
    public let heldCount: Int

    /// The held run results, in queue order.
    public let heldMail: [HeldMail]

    /// One line for a person, the text of the report of the agent.
    public let message: String

    /// Makes a pause.
    ///
    /// - Parameters:
    ///   - limit: The limit in force.
    ///   - heldCount: How many run results the session holds.
    ///   - heldMail: The held run results, in queue order.
    ///   - message: The text for a person.
    public init(limit: Int, heldCount: Int, heldMail: [HeldMail], message: String) {
        self.limit = limit
        self.heldCount = heldCount
        self.heldMail = heldMail
        self.message = message
    }
}

/// One run result that a paused session holds.
public struct HeldMail: Identifiable, Hashable, Sendable {
    /// The tool of the run.
    public let tool: String

    /// The operation of the run.
    public let op: String

    /// The completion token of the run. It names the run, so it is the
    /// identity of the held result.
    public let completionToken: String

    /// The identity of the held result: its ``completionToken``.
    public var id: String {
        completionToken
    }

    /// Makes a held result.
    ///
    /// - Parameters:
    ///   - tool: The tool of the run.
    ///   - op: The operation of the run.
    ///   - completionToken: The completion token of the run.
    public init(tool: String, op: String, completionToken: String) {
        self.tool = tool
        self.op = op
        self.completionToken = completionToken
    }
}

extension MailDeliveryPause {
    /// The `sessionUpdate` value of the extension update.
    static let kind = "_mail_delivery_paused"

    /// Tells whether an update is a `_mail_delivery_paused` update, also when
    /// ``decode(_:)`` ignores it.
    ///
    /// - Parameter update: The session update.
    /// - Returns: `true` only for an update with the exact kind
    ///   `_mail_delivery_paused`. Each other update, also an unknown update of
    ///   another kind, gives `false`, so it goes to the merge engine.
    static func isPauseUpdate(_ update: SessionUpdate) -> Bool {
        payload(of: update) != nil
    }

    /// Reads a `_mail_delivery_paused` update from the raw JSON of a
    /// `SessionUpdate.unknown`.
    ///
    /// `limit` and `heldCount` must be whole numbers, `message` a string, and
    /// `heldMail` an array of objects that each have the strings `tool`, `op`
    /// and `completionToken`. When a member is missing or has the wrong type,
    /// the decode ignores the whole update. It ignores a member that it does
    /// not know.
    ///
    /// - Parameter update: The session update.
    /// - Returns: The pause, or `nil` for each other update and for each pause
    ///   update that the decode ignores.
    static func decode(_ update: SessionUpdate) -> MailDeliveryPause? {
        guard case .object(let members)? = payload(of: update),
            let limit = wholeNumber(members["limit"]),
            let heldCount = wholeNumber(members["heldCount"]),
            case .string(let message) = members["message"],
            case .array(let heldValues) = members["heldMail"]
        else {
            return nil
        }
        let heldMail = heldValues.compactMap(HeldMail.init(wire:))
        guard heldMail.count == heldValues.count else { return nil }
        return MailDeliveryPause(limit: limit, heldCount: heldCount, heldMail: heldMail, message: message)
    }

    /// Gives the raw payload of an update when its kind is exactly
    /// `_mail_delivery_paused`.
    ///
    /// - Parameter update: The session update.
    /// - Returns: The payload, or `nil` for each update of another kind.
    private static func payload(of update: SessionUpdate) -> JSONValue? {
        guard case .unknown(let updateKind, let payload) = update, updateKind == kind else { return nil }
        return payload
    }

    /// Reads a whole number from a member.
    ///
    /// - Parameter value: The value of the member, or `nil`.
    /// - Returns: The number, or `nil` when the value is missing, is not a
    ///   number, or is not a whole number.
    private static func wholeNumber(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.rounded() == number,
            let whole = Int(exactly: number)
        else { return nil }
        return whole
    }
}

extension HeldMail {
    /// Reads one held result of a `_mail_delivery_paused` update.
    ///
    /// - Parameter value: One element of the `heldMail` array.
    /// - Returns: The held result, or `nil` when the value is not an object
    ///   with the strings `tool`, `op` and `completionToken`.
    init?(wire value: JSONValue) {
        guard case .object(let members) = value,
            case .string(let tool) = members["tool"],
            case .string(let op) = members["op"],
            case .string(let completionToken) = members["completionToken"]
        else {
            return nil
        }
        self.init(tool: tool, op: op, completionToken: completionToken)
    }
}
