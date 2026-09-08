import Foundation
import Testing

// The source-level half of the `Ctrl-C` rule of `cli-plan.md` §11: the event
// handler `InterruptHandler` gives its `DispatchSourceSignal` sets a flag and
// calls nothing else. The work a press asks for — the wire cancel, the end of
// the run — runs on a normal task that reads the flag.
//
// No behavioural test can state that. A handler that took a lock, advanced a
// counter and ran the callbacks in the event handler itself would pass every
// row of `InterruptHandlerTests` and `InterruptTests` alike, because the
// callbacks would still run. So this file reads the source, takes the body of
// the `setEventHandler` closure, and asserts its shape: one statement, and
// that statement the store into the flag.

/// The repository-relative path of the file that arms the signal source.
private let interruptHandlerPath = "Sources/AcpClientCore/InterruptHandler.swift"

/// The text that opens the event handler closure the source is given.
private let eventHandlerOpening = "setEventHandler {"

/// The text that opens the one statement the handler body may hold: the store
/// into the flag.
///
/// The flag is `pendingInterrupts`, and `add` is the store, because a dispatch
/// signal source coalesces a fast double press into one event carrying a count
/// of two, so the flag has to carry a count and not a `Bool`. The `self.` is
/// what an escaping closure of a class writes in place of a capture clause,
/// and a capture clause would be a second line of the body.
private let flagStoreOpening = "self.pendingInterrupts.add("

/// How many statements the handler body may hold.
private let oneStatement = 1

/// How many calls the one statement may hold: the store into the flag.
private let oneCall = 1

/// The text that opens a line comment.
private let lineCommentOpening = "//"

/// Returns the text between the braces of the event handler closure, or `nil`
/// when the source holds no such closure or the closure never closes.
///
/// The scan counts braces from the opening one, so a nested closure inside the
/// body stays inside the body.
///
/// - Parameter source: The whole text of the file.
/// - Returns: The closure body, without its own braces.
private func eventHandlerBody(in source: String) -> String? {
    guard let opening = source.range(of: eventHandlerOpening) else { return nil }
    var depth = 1
    var index = opening.upperBound
    while index < source.endIndex {
        let character = source[index]
        if character == "{" {
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 {
                return String(source[opening.upperBound..<index])
            }
        }
        index = source.index(after: index)
    }
    return nil
}

/// Returns the lines of `body` that carry a statement: not blank, and not a
/// line comment.
///
/// - Parameter body: The closure body to read.
/// - Returns: Each statement line, trimmed.
private func statementLines(of body: String) -> [String] {
    body
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix(lineCommentOpening) }
}

/// The shape of the event handler `InterruptHandler` gives its signal source.
@Suite("acp-client interrupt handler source")
struct InterruptHandlerSourceTests {
    /// The event handler body sets the flag and calls nothing else. A body that
    /// took a lock or ran a callback would do the run's work inside the
    /// dispatch handler, and `cli-plan.md` §11 puts that work on a normal task.
    @Test("the signal source's event handler sets the flag and calls nothing else")
    func theEventHandlerSetsTheFlagAndCallsNothingElse() throws {
        let source = try RepositoryFile.read(relativePath: interruptHandlerPath)

        let body = try #require(
            eventHandlerBody(in: source),
            "no `\(eventHandlerOpening)` closure stands in \(interruptHandlerPath)"
        )
        let statements = statementLines(of: body)

        #expect(statements.count == oneStatement, "the handler body holds \(statements)")
        let statement = try #require(statements.first, "the handler body is empty")
        #expect(statement.hasPrefix(flagStoreOpening), "the statement is \"\(statement)\"")
        #expect(
            statement.filter { $0 == "(" }.count == oneCall,
            "the statement calls more than the store: \"\(statement)\""
        )
    }
}
