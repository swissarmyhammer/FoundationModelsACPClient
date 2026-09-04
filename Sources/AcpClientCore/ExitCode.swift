import ArgumentParser
import FoundationModelsACP
import FoundationModelsExtras

/// The failure `--timeout` throws when a run reaches its time limit.
///
/// It is a marker and carries nothing, because the limit it broke is the
/// caller's own option and the caller is what says so on stderr. What the type
/// carries instead is the exit code: ``AcpClientExitCode/forError(_:)`` reads
/// this one type and answers ``AcpClientExitCode/timeout``, so no other error
/// can reach 124 and this one cannot reach anything else.
struct AcpClientTimeout: Error, CustomStringConvertible {
    /// A human-readable description of this error.
    var description: String {
        "The run reached the limit --timeout gave it, and ended."
    }
}

/// The exit code table of `cli-plan.md` §9.
///
/// The table is one value with no I/O of its own, so the outcome of a run and
/// the number the process exits with are decided in one place. `cli-plan.md`
/// §17 gives `acp-agent` the same table, and a table that is one value is a
/// table two binaries can be compared against line by line.
///
/// | Code | Meaning |
/// |---|---|
/// | 0 | `end_turn`, or a report that ran |
/// | 1 | An error: spawn, protocol, or I/O. `doctor` found an error. |
/// | 2 | A usage error |
/// | 3 | `refusal` |
/// | 4 | `cancelled` |
/// | 5 | `doctor` found warnings, and no error |
/// | 124 | A timeout, which is the `timeout(1)` convention |
///
/// Code 5 is the row that needs a reason. The Rust doctor exits 2 for an
/// error, and 2 is already the usage error here, so a script would read a
/// broken configuration as a typing mistake. `doctor-plan.md` §5 moved the
/// warning verdict to 5 to keep the two apart.
enum AcpClientExitCode: Int32, Sendable, CaseIterable {
    /// The turn ended, or the report ran. `cli-plan.md` §9, row 0.
    case success = 0

    /// A spawn, protocol or I/O error, or a `doctor` run that found an error.
    /// `cli-plan.md` §9, row 1.
    case failure = 1

    /// A mistake on the command line. `cli-plan.md` §9, row 2.
    ///
    /// ArgumentParser's own `ExitCode.validationFailure` is `EX_USAGE`, which
    /// is 64. §9 does not use 64: it pins a usage error at 2, so that this
    /// binary and `acp-agent` report the same code for the same mistake.
    case usage = 2

    /// The agent refused to continue the turn. `cli-plan.md` §9, row 3.
    case refusal = 3

    /// The turn was cancelled. `cli-plan.md` §9, row 4.
    case cancelled = 4

    /// A `doctor` run that found warnings and no error. `cli-plan.md` §9,
    /// row 5.
    ///
    /// This row is 5 and not 2 because the Rust doctor's code 2 for errors
    /// would collide with ``usage``. `doctor-plan.md` §5 records the decision.
    case doctorWarning = 5

    /// The run reached its time limit. `cli-plan.md` §9, row 124.
    ///
    /// 124 is the `timeout(1)` convention, so a script that already reads that
    /// number reads this binary with no change.
    case timeout = 124

    /// This row as the parser's own exit value.
    ///
    /// A subcommand body ends its run by throwing this. ArgumentParser reads an
    /// `ExitCode` error as an empty message and the number it carries, so
    /// `exit(withError:)` prints nothing and exits with exactly this row —
    /// leaving standard output to the answer text, as `cli-plan.md` §8 requires.
    ///
    /// This is the one member of the target that turns a row into a number, so
    /// the §9 table stays in this file and no command body spells a literal.
    var parserExitCode: ExitCode {
        ExitCode(rawValue)
    }

    /// The exit code of an `idle` that reports no stop reason at all.
    ///
    /// `IdleStateUpdate.stopReason` is optional, and the schema says "Omitted
    /// or `null` both mean the agent is not reporting a stop reason". An agent
    /// that went idle without saying why still went idle, so the turn is over
    /// and the run succeeded. A caller reads this where it has no reason to
    /// hand ``forStopReason(_:)``.
    static let idleWithNoReason: AcpClientExitCode = .success

    /// Returns the exit code `cli-plan.md` §9 gives one stop reason.
    ///
    /// The switch has no `default` arm, so a case the schema adds later is a
    /// build failure here rather than a wrong number at run time.
    ///
    /// - Parameter reason: Why the agent stopped the turn.
    /// - Returns: The exit code that outcome owes.
    static func forStopReason(_ reason: StopReason) -> AcpClientExitCode {
        switch reason {
        case .endTurn, .maxTokens, .maxTurnRequests:
            // A turn that ran out of tokens or of requests still ended, and
            // §9 gives the whole row to `end_turn`.
            .success
        case .refusal:
            .refusal
        case .cancelled:
            .cancelled
        case .unknown:
            // An agent that ended its turn for a reason this build does not
            // know still ended its turn. A non-zero code would make every
            // future addition to the schema look like a failure.
            .success
        }
    }

    /// Returns the exit code `cli-plan.md` §9 gives one doctor verdict.
    ///
    /// `DoctorReport.exitCode` of `FoundationModelsExtras` answers the same
    /// three numbers for a whole report. This function answers for one status,
    /// which is what folds the doctor verdict into the one §9 table beside
    /// every other outcome of the binary.
    ///
    /// - Parameter status: The worst finding of a doctor report.
    /// - Returns: The exit code that verdict owes.
    static func forDoctorStatus(_ status: HealthStatus) -> AcpClientExitCode {
        switch status {
        case .ok:
            .success
        case .warning:
            .doctorWarning
        case .error:
            .failure
        }
    }

    /// Returns the exit code `cli-plan.md` §9 gives one error.
    ///
    /// ArgumentParser stays the classifier of a usage mistake:
    /// `exitCode(for:)` is what decides whether an error came out of the
    /// parser or out of a `validate()`. Only the number changes, because §9
    /// and `EX_USAGE` disagree there.
    ///
    /// The timeout is read first, because ArgumentParser reads an error it
    /// does not know as a plain failure and ``AcpClientTimeout`` is one of
    /// those.
    ///
    /// - Parameter error: The error the run ended with.
    /// - Returns: ``usage`` for a parsing or validation error, ``timeout`` for
    ///   ``AcpClientTimeout``, and ``failure`` for everything else — a spawn,
    ///   a protocol or an I/O error.
    static func forError(_ error: any Error) -> AcpClientExitCode {
        guard !(error is AcpClientTimeout) else { return .timeout }
        guard AcpClient.exitCode(for: error) != .validationFailure else { return .usage }
        return .failure
    }
}
