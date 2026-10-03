import Foundation
import FoundationModelsACP

/// **UNSTABLE**
///
/// One notice that the agent sent for the user, as ``SessionModel/notices``
/// holds it.
///
/// A notice is a live event and not session history. It never goes into the
/// transcript, the merge engine does not replay it, and the model removes it
/// on ``SessionModel/dismissNotice(_:)``, at the start of a resume, and at
/// the close. The value wraps the wire notice and adds a local identity and
/// the time of its arrival.
public struct SessionNotice: Identifiable, Hashable, Sendable {
    /// The local identity of the notice. The wire notice has no identifier,
    /// so two equal notices get two identities.
    public let id: UUID

    /// The notice as the agent sent it.
    public let notice: Unstable.Notice

    /// The time of arrival: the time on the clock of the model from the
    /// creation of the model to the arrival of the notice.
    public let arrivalTime: Duration

    /// The presentation severity that the agent gave.
    public var severity: Unstable.NoticeSeverity {
        notice.severity
    }

    /// The plain-text title, which can stand alone.
    public var title: String {
        notice.title
    }

    /// The plain-text detail or guidance, or `nil` when the agent gave none.
    public var description: String? {
        notice.description
    }

    /// The `_meta` field of the notice, or `nil` when the agent gave none.
    public var meta: JSONValue? {
        notice.meta
    }

    /// Makes the notice of one arrival, with a new local identity.
    ///
    /// - Parameters:
    ///   - notice: The notice as the agent sent it.
    ///   - arrivalTime: The time on the clock of the model at the arrival.
    init(notice: Unstable.Notice, arrivalTime: Duration) {
        self.id = UUID()
        self.notice = notice
        self.arrivalTime = arrivalTime
    }
}
