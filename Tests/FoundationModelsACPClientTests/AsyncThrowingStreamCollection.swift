// The stream reader that the GraphQL tests share. A test of a subscription
// reads the whole stream, and then examines the elements and the error that
// ended the stream. One reader serves each such test, so the tests cannot
// disagree about how to read a stream to its end.
//
// The integration package keeps its own copy of this reader, in
// `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/GraphQLTunnelTests.swift`.
// If you change one copy, change the other copy also.

extension AsyncThrowingStream where Failure == any Error {
    /// Reads each element of the stream until it ends.
    ///
    /// The reader keeps the elements that came before an error, so the
    /// result holds a list that grows during the read, and not a `map` of
    /// the stream.
    ///
    /// - Returns: The elements, and the error that ended the stream, or `nil`
    ///   for a normal finish.
    func collect() async -> (elements: [Element], error: (any Error)?) {
        var elements: [Element] = []
        do {
            for try await element in self {
                elements.append(element)
            }
            return (elements, nil)
        } catch {
            return (elements, error)
        }
    }
}
