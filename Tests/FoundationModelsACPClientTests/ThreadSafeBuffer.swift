import Synchronization

// The capture the concurrent tests share. A test that watches work happening
// on another task or another thread cannot capture that work in a plain array
// or a plain `String`, because the writer appends while the test body reads.
// For example, `PermissionReplyOrderTests` captures the lines that a
// `FrameRecordingTransport` reads on its forwarding task. One buffer serves
// each such test, so the tests cannot disagree about what a thread-safe
// capture is.

/// A thread-safe append-only list.
///
/// The writer appends from a task or a thread of its own while the test body
/// reads, so the capture cannot be a plain array.
final class ThreadSafeBuffer<Element: Sendable>: Sendable {
    /// Everything appended so far, in order.
    private let storage = Mutex<[Element]>([])

    /// Appends one element, exactly as it was given.
    ///
    /// - Parameter element: The element to record, with nothing added and
    ///   nothing removed.
    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    /// Everything appended so far, in order.
    var elements: [Element] {
        storage.withLock { $0 }
    }
}

extension ThreadSafeBuffer where Element == String {
    /// Everything appended so far, end to end.
    ///
    /// A text sink receives whatever chunks the writer chose to send, and an
    /// assertion about the bytes wants the text and not the chunk boundaries.
    var text: String {
        elements.joined()
    }
}
