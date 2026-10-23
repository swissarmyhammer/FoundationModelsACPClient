import Foundation

/// The two directories that the test gives a server on its command line.
public struct LaunchArguments {
    /// A command line that does not hold exactly the two directories.
    public enum Failure: Error, CustomStringConvertible {
        /// The command line held this count of arguments after the
        /// executable path.
        case wrongArgumentCount(Int)

        /// The usage text, with the count that the command line held.
        public var description: String {
            switch self {
            case .wrongArgumentCount(let count):
                "usage: <server> <state-directory> <working-directory> (got \(count) arguments)"
            }
        }
    }

    /// The directory that holds the user layer and the recordings of the
    /// agent.
    public let stateDirectory: URL

    /// The working directory of the configuration load.
    public let workingDirectory: URL

    /// Reads the two directories from a command line.
    ///
    /// - Parameter commandLine: The command line: the executable path, then
    ///   the state directory and the working directory.
    /// - Throws: ``Failure/wrongArgumentCount(_:)`` when the command line
    ///   does not hold exactly two directories after the executable path.
    public init(commandLine: [String]) throws {
        let directories = commandLine.dropFirst().map { URL(filePath: $0, directoryHint: .isDirectory) }
        guard let stateDirectory = directories.first,
            let workingDirectory = directories.last,
            directories.count == Self.directoryCount
        else {
            throw Failure.wrongArgumentCount(directories.count)
        }
        self.stateDirectory = stateDirectory
        self.workingDirectory = workingDirectory
    }

    /// The count of directories on the command line.
    private static let directoryCount = 2
}
