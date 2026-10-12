import FoundationModelsACP

extension JSONValue {
    /// Gives the text of one string member of a JSON object.
    ///
    /// The payload of an unknown wire case is a `JSONValue`. This reads one
    /// field of that payload, for example the `name` of an MCP server or the
    /// `methodId` of an auth method that this schema revision does not know.
    ///
    /// - Parameter key: The name of the member.
    /// - Returns: The text, or `nil` when this value is not an object, or when
    ///   the object has no member `key` with a string value.
    func stringMember(_ key: String) -> String? {
        guard case .object(let members) = self, case .string(let text)? = members[key] else {
            return nil
        }
        return text
    }
}
