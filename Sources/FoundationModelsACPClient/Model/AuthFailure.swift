import Foundation
import FoundationModelsACP
import Logging

/// The record of an auth operation that failed, for a UI to observe.
///
/// ``ConnectionModel`` keeps this value in ``AuthState/failed(_:)``. The
/// value tells which operation failed and why, so a UI can show "sign-in
/// failed" and "sign-out failed" differently.
public struct AuthFailure: Hashable, Sendable {
    /// The auth operation that failed.
    public enum Operation: Hashable, Sendable {
        /// An `auth/login` with this auth method.
        case login(AuthMethodId)

        /// An `auth/logout`.
        case logout

        /// A run of this `terminal` auth method as a separate process.
        case terminalLogin(AuthMethodId)
    }

    /// The reason that the operation failed.
    ///
    /// A request that went out and failed gives ``request(_:)``. A terminal
    /// auth process that failed gives ``terminal(exitStatus:message:)``. An
    /// operation that the model did not start, because the agent does not
    /// advertise it, gives ``unsupported(method:)``. ``message`` gives a text
    /// that a UI can show for each reason.
    public enum Reason: Hashable, Sendable {
        /// The request failed with this JSON-RPC error. A refusal of the
        /// agent, a closed connection, a time-out, and a cancel each have
        /// one JSON-RPC form.
        case request(RequestError)

        /// The terminal auth process failed.
        ///
        /// - Parameters:
        ///   - exitStatus: The exit status of the process, or `nil` when the
        ///     process did not exit normally.
        ///   - message: A message about the failure, or `nil` when there is
        ///     none.
        case terminal(exitStatus: Int32?, message: String?)

        /// The agent does not advertise the operation, so the model sent
        /// nothing and ran no process. The operation also threw
        /// ``ConnectionModelError/unsupported(method:)`` with the same
        /// `method`.
        ///
        /// - Parameter method: The ACP wire method of the operation, or
        ///   ``ConnectionModelError/terminalAuthOperation`` for a terminal
        ///   login.
        case unsupported(method: String)

        /// A text about the failure that a UI can show.
        ///
        /// Each text comes from the string catalog of this package, in the
        /// language of the user, so a host app can translate it.
        ///
        /// - ``request(_:)``: the message of the JSON-RPC error.
        /// - ``terminal(exitStatus:message:)``: the message of the failure
        ///   when there is one. If not, a text that gives the exit status, or
        ///   that says that the process did not stop normally.
        /// - ``unsupported(method:)``: a text that says that the agent cannot
        ///   do this auth operation.
        public var message: String {
            switch self {
            case .request(let error):
                MessageKey.request.text(formatting: error.message)
            case .terminal(_, let message?):
                MessageKey.terminalMessage.text(formatting: message)
            case .terminal(let exitStatus?, nil):
                MessageKey.terminalExitStatus.text(formatting: exitStatus)
            case .terminal(nil, nil):
                MessageKey.terminalAbnormalStop.text
            case .unsupported:
                MessageKey.unsupported.text
            }
        }

        /// The key of each text of ``message`` in the string catalog of this
        /// package.
        ///
        /// The agent or the host writes the text of a request error and the
        /// message of a terminal failure. The catalog does not translate these
        /// texts. It holds a format that puts each text into the message, so a
        /// translation can add words around the text.
        enum MessageKey: String, CaseIterable {
            /// The format of the message of a JSON-RPC error. The argument is
            /// the message of the error.
            case request = "auth.failure.request"

            /// The format of the message of a terminal auth process. The
            /// argument is the message of the failure.
            case terminalMessage = "auth.failure.terminal.message"

            /// The format of the text of a terminal auth process that exited
            /// with no message. The argument is the exit status.
            case terminalExitStatus = "auth.failure.terminal.exitStatus"

            /// The text of a terminal auth process that did not exit normally
            /// and gave no message.
            case terminalAbnormalStop = "auth.failure.terminal.abnormalStop"

            /// The text of an auth operation that the agent does not
            /// advertise.
            case unsupported = "auth.failure.unsupported"

            /// The resource bundle that holds the string catalog of this
            /// module.
            static var bundle: Bundle { .module }

            /// The log metadata key that holds the catalog key with no entry.
            static let missingEntryMetadataKey = "localization.key"

            /// The text of this key, in the language of the user.
            ///
            /// The catalog has an entry for each key. When an entry is
            /// missing, ``recordMissingEntry(_:)`` records the defect, and the
            /// key itself is the text, so a missing entry is easy to see.
            var text: String {
                text(in: Self.bundle, reportingMissingEntry: Self.recordMissingEntry)
            }

            /// The text of this key in the string table of a bundle.
            ///
            /// - Parameters:
            ///   - bundle: The bundle that holds the string table.
            ///   - report: Receives the key when the string table has no entry
            ///     for it.
            /// - Returns: The text of the entry, or the key when there is no
            ///   entry.
            func text(in bundle: Bundle, reportingMissingEntry report: (String) -> Void) -> String {
                let entry = bundle.localizedString(forKey: rawValue, value: nil, table: nil)
                guard entry != rawValue else {
                    report(rawValue)
                    return rawValue
                }
                return entry
            }

            /// Records a catalog key with no entry: the assertion stops a debug
            /// build, and the log records the defect in a release build.
            ///
            /// - Parameter key: The catalog key with no entry.
            static func recordMissingEntry(_ key: String) {
                assertionFailure("no catalog entry for \(key)")
                Logger(label: ACPClientTelemetry.logLabel).error(
                    "The string catalog has no entry for the key \(key); the key stands as the text.",
                    metadata: [missingEntryMetadataKey: "\(key)"]
                )
            }

            /// Puts the arguments into the format of this key.
            ///
            /// The current locale formats each number argument.
            ///
            /// - Parameter arguments: The format arguments, in the order of
            ///   the format of the source language.
            /// - Returns: The text of this key with the arguments in it.
            func text(formatting arguments: any CVarArg...) -> String {
                String(format: text, locale: .current, arguments: arguments)
            }
        }
    }

    /// The auth operation that failed.
    public let operation: Operation

    /// The reason that the operation failed.
    public let reason: Reason

    /// Makes a failure record.
    ///
    /// - Parameters:
    ///   - operation: The auth operation that failed.
    ///   - reason: The reason that the operation failed.
    public init(operation: Operation, reason: Reason) {
        self.operation = operation
        self.reason = reason
    }
}
