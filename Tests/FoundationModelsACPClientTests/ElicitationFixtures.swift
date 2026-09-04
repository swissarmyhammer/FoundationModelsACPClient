import FoundationModelsACP

// This file holds the shared builders for the elicitation tests. The
// container tests and the declining-client tests of the binary both need the
// same two wire requests, and the one difference between their copies was the
// scope, so the scope is a parameter here.
//
// The builders are static members of a namespace, so every function belongs
// to a type and no function stands alone at file scope.

/// The shared wire fixtures that the elicitation tests send.
enum ElicitationFixtures {
    /// The message that each form request carries.
    static let formMessage = "Name the deployment"

    /// The message that each url request carries.
    static let urlMessage = "Finish sign-in in the browser"

    /// The form schema that each form request carries: one required "name"
    /// string.
    static let nameSchema = ElicitationSchema(
        properties: .object(["name": .object(["type": .string("string")])]),
        required: ["name"]
    )

    /// The elicitation id that each url request carries.
    static let urlID = ElicitationId(rawValue: "elicit-1")

    /// The URL that each url request points at.
    static let urlString = "https://example.test/verify"

    /// The scope of an elicitation that belongs to the test session.
    static let sessionScope = ElicitationSessionScope(sessionId: testSession)

    /// The scope of an elicitation that belongs to one JSON-RPC request.
    ///
    /// It models an elicitation that arrives before any session exists, for
    /// example during authentication.
    static let requestScope = ElicitationRequestScope(requestId: .string("req-1"))

    /// Makes a form-mode elicitation request.
    ///
    /// - Parameter scope: The scope the request carries.
    /// - Returns: The request, with the one-field test schema.
    static func formRequest(scope: ElicitationFormMode.Scope) -> CreateElicitationRequest {
        CreateElicitationRequest(
            message: formMessage,
            mode: .form(ElicitationFormMode(requestedSchema: nameSchema, scope: scope))
        )
    }

    /// Makes a url-mode elicitation request.
    ///
    /// - Parameter scope: The scope the request carries.
    /// - Returns: The request.
    static func urlRequest(scope: ElicitationUrlMode.Scope) -> CreateElicitationRequest {
        CreateElicitationRequest(
            message: urlMessage,
            mode: .url(
                ElicitationUrlMode(elicitationId: urlID, url: urlString, scope: scope)
            )
        )
    }
}
