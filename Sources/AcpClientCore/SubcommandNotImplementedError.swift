/// The error a subcommand body throws while its work is not yet written.
///
/// `cli-plan.md` §15 splits this binary into milestones, and N1 is the command
/// tree alone: the grammar, `--help`, `--version` and the usage errors are
/// real, and the three bodies are not. This error is what a body throws in the
/// meantime, so that a person who runs the binary early gets a sentence naming
/// the milestone rather than silence or a wrong answer.
///
/// It is one type and not three messages, so the three bodies cannot describe
/// the same state in three ways. Each milestone deletes its own throw.
struct SubcommandNotImplementedError: Error, CustomStringConvertible {
    /// The name of the subcommand, as it appears on the command line.
    let commandName: String

    /// The milestone of `cli-plan.md` §15 that writes the body.
    let milestone: String

    /// A human-readable description of this error.
    var description: String {
        """
        The "\(commandName)" subcommand is not implemented yet. \
        Milestone \(milestone) of cli-plan.md section 15 writes it.
        """
    }
}
