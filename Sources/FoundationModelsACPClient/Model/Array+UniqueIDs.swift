import FoundationModelsACP

// The rule that keeps one element for each id in each list that the model
// fills from the wire. A SwiftUI view uses `ForEach(list)` on these lists,
// and two elements with the same id give undefined rows. The agent can send
// such a list, so the model removes the repeats and logs one warning.

extension Array where Element: Identifiable {
    /// Gives the list with one element for each id.
    ///
    /// When an id comes more than one time, the last element with that id
    /// goes in the position of the first element with that id. Each other
    /// element keeps its order.
    ///
    /// - Returns: The list with one element for each id, and each id that
    ///   came more than one time, in the order of its first repeat.
    func keepingLastOfEachID() -> (elements: [Element], repeatedIDs: [Element.ID]) {
        var positions: [Element.ID: Int] = [:]
        var elements: [Element] = []
        var repeatedIDs: [Element.ID] = []
        for element in self {
            guard let position = positions[element.id] else {
                positions[element.id] = elements.count
                elements.append(element)
                continue
            }
            elements[position] = element
            if !repeatedIDs.contains(element.id) {
                repeatedIDs.append(element.id)
            }
        }
        return (elements, repeatedIDs)
    }

    /// Gives the list with one element for each id, and logs one warning
    /// when an id comes more than one time.
    ///
    /// See ``keepingLastOfEachID()`` for the rule. A list with no repeated
    /// id logs nothing.
    ///
    /// - Parameters:
    ///   - list: The name of the list in the model, for the warning. For
    ///     example `"SessionModel.availableCommands"`.
    ///   - logger: The diagnostic sink of the connection.
    /// - Returns: The list with one element for each id.
    func keepingLastOfEachID(in list: String, warningTo logger: ACPLogger) -> [Element] {
        let unique = keepingLastOfEachID()
        if !unique.repeatedIDs.isEmpty {
            logger.log(Self.repeatedIDsWarning(unique.repeatedIDs, in: list))
        }
        return unique.elements
    }

    /// Gives the warning for a list from the agent with repeated ids.
    ///
    /// - Parameters:
    ///   - repeatedIDs: Each id that came more than one time.
    ///   - list: The name of the list in the model.
    /// - Returns: The warning, with the list and each repeated id.
    private static func repeatedIDsWarning(_ repeatedIDs: [Element.ID], in list: String) -> String {
        let ids = repeatedIDs.map { "\"\(String(describing: $0))\"" }.joined(separator: ", ")
        return "\(list): the agent sent more than one element with the id \(ids); "
            + "the list keeps the last element of each id, in the position of the first"
    }
}
