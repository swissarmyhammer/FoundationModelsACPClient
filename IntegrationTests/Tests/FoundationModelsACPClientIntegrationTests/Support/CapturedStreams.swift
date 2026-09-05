import Foundation

// The two readings a suite makes of a captured stream. `CLIResult` keeps each
// stream as `Data`, so a test can assert on bytes. These two turn the bytes
// into text only where a test splits lines, or writes the failure message that
// says what the stream really held.

/// Renders one captured stream as text.
///
/// The assertions compare BYTES; this is for the line splitting a few of them
/// do, and for the failure message that says what the stream really held.
///
/// - Parameter stream: The captured bytes.
/// - Returns: The bytes as text, with invalid UTF-8 replaced rather than
///   dropped.
func text(_ stream: Data) -> String {
    String(decoding: stream, as: UTF8.self)
}

/// Splits one captured stream into its non-empty lines.
///
/// - Parameter stream: The captured bytes.
/// - Returns: The lines, without their terminators.
func lines(of stream: Data) -> [String] {
    text(stream).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}
