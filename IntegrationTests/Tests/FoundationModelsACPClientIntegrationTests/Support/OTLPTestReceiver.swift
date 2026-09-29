import Foundation
import Synchronization

// This file holds a small OTLP/HTTP receiver for the telemetry suite. The
// suite points `OTEL_EXPORTER_OTLP_ENDPOINT` at it, runs the real `acp-client`
// binary, and then reads which requests arrived.
//
// The receiver binds the IPv4 loopback address only, on a port that the kernel
// gives, so no other host can reach it and no two runs can share a port.

/// The failures of a loopback socket that the telemetry suite opens.
enum LoopbackSocketError: Error, CustomStringConvertible {
    /// No loopback socket could be opened, bound or read, and `errno` says why.
    case unavailable(errno: Int32)

    /// A human-readable description of this error.
    var description: String {
        switch self {
        case .unavailable(let errno):
            return "No free loopback port could be found (errno \(errno))."
        }
    }
}

/// Opens IPv4 stream sockets on a free port of the loopback address.
enum LoopbackSocket {
    /// The loopback address that every socket of this type binds.
    static let address = "127.0.0.1"

    /// The port number that asks the kernel for a free port.
    private static let anyFreePort: in_port_t = 0

    /// The number of `sockaddr` values the rebound address pointer covers.
    private static let oneSocketAddress = 1

    /// Returns the `http` endpoint URL text for a port of the loopback address.
    ///
    /// - Parameter port: The port, in host byte order.
    /// - Returns: The endpoint URL text.
    static func endpoint(port: in_port_t) -> String {
        "http://\(address):\(port)"
    }

    /// Opens an IPv4 stream socket and binds it to a free loopback port.
    ///
    /// - Returns: The open socket, and the port the kernel gave, in host byte
    ///   order. The caller closes the socket.
    /// - Throws: ``LoopbackSocketError/unavailable(errno:)`` when the socket
    ///   cannot be opened, bound or read.
    static func bound() throws -> (descriptor: Int32, port: in_port_t) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LoopbackSocketError.unavailable(errno: errno)
        }
        do {
            return (descriptor, try bindToFreePort(descriptor))
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Binds `descriptor` to a free loopback port and returns that port.
    ///
    /// - Parameter descriptor: An open IPv4 stream socket.
    /// - Returns: The port number the kernel gave, in host byte order.
    /// - Throws: ``LoopbackSocketError/unavailable(errno:)`` when the bind or
    ///   the read of the address fails.
    private static func bindToFreePort(_ descriptor: Int32) throws -> in_port_t {
        var socketAddress = sockaddr_in()
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = anyFreePort
        socketAddress.sin_addr.s_addr = inet_addr(address)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: oneSocketAddress) { generic in
                bind(descriptor, generic, length) == 0
                    && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else {
            throw LoopbackSocketError.unavailable(errno: errno)
        }
        return in_port_t(bigEndian: socketAddress.sin_port)
    }
}

/// How the test receiver answers each request it reads.
enum OTLPTestReceiverReply: Sendable {
    /// Answers each request with an empty OTLP success, as a collector does.
    case success

    /// Reads each request and never answers, as a collector that hangs does.
    case none
}

/// A loopback OTLP/HTTP receiver that records the path of each request.
///
/// Each connection gets a thread of its own, so a request can arrive on a
/// second connection while the first one waits. The receiver records the path
/// of a request before it answers. So when the exporter of the binary received
/// the answer, the record is already there.
final class OTLPTestReceiver: Sendable {
    /// The `http` endpoint URL text to put in `OTEL_EXPORTER_OTLP_ENDPOINT`.
    let endpoint: String

    /// The listening socket.
    private let listener: Int32

    /// The read end of the pipe that ``stop()`` writes to.
    private let wakeReader: Int32

    /// The write end of the pipe that ``stop()`` writes to.
    private let wakeWriter: Int32

    /// How this receiver answers each request.
    private let reply: OTLPTestReceiverReply

    /// The path of each request, in the order the requests arrived.
    private let paths = Mutex<[String]>([])

    /// The bytes that end the head of an HTTP request.
    private static let headTerminator = Array("\r\n\r\n".utf8)

    /// The line break between two lines of the head of an HTTP request.
    private static let lineBreak: Character = "\r\n"

    /// The separator between the name and the value of a header field.
    private static let fieldSeparator: Character = ":"

    /// The separator between the parts of the request line.
    private static let requestLineSeparator: Character = " "

    /// The name of the header field that gives the length of the body, in
    /// lowercase. HTTP compares field names without regard to case.
    private static let contentLengthField = "content-length"

    /// The answer to a request: an empty OTLP export response, which decodes
    /// as a full success.
    private static let successResponse = Array(
        "HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\nContent-Length: 0\r\n\r\n".utf8
    )

    /// The largest number of bytes one read takes from a connection.
    private static let readChunkSize = 4096

    /// The byte that ``stop()`` writes to wake the accept loop.
    private static let wakeByte: UInt8 = 1

    /// The timeout value that makes `poll` wait with no limit.
    private static let noPollTimeout: Int32 = -1

    /// Creates a receiver over sockets that are already open.
    ///
    /// - Parameters:
    ///   - listener: The listening socket.
    ///   - port: The port of the listening socket, in host byte order.
    ///   - wakePipe: The two ends of the pipe that ``stop()`` writes to.
    ///   - reply: How the receiver answers each request.
    private init(
        listener: Int32,
        port: in_port_t,
        wakePipe: (reader: Int32, writer: Int32),
        reply: OTLPTestReceiverReply
    ) {
        self.endpoint = LoopbackSocket.endpoint(port: port)
        self.listener = listener
        self.wakeReader = wakePipe.reader
        self.wakeWriter = wakePipe.writer
        self.reply = reply
    }

    /// Opens a receiver on a free loopback port and starts to accept
    /// connections.
    ///
    /// The socket listens before this function returns, so a run that starts
    /// after it can connect at once.
    ///
    /// - Parameter reply: How the receiver answers each request.
    /// - Returns: The running receiver. The caller calls ``stop()``.
    /// - Throws: ``LoopbackSocketError/unavailable(errno:)`` when the socket
    ///   or the pipe cannot be made.
    static func start(replying reply: OTLPTestReceiverReply) throws -> OTLPTestReceiver {
        let (listener, port) = try LoopbackSocket.bound()
        var pipeEnds: [Int32] = [0, 0]
        guard listen(listener, SOMAXCONN) == 0, pipe(&pipeEnds) == 0 else {
            let failure = errno
            close(listener)
            throw LoopbackSocketError.unavailable(errno: failure)
        }
        let receiver = OTLPTestReceiver(
            listener: listener,
            port: port,
            wakePipe: (reader: pipeEnds[0], writer: pipeEnds[1]),
            reply: reply
        )
        Thread.detachNewThread { receiver.acceptConnections() }
        return receiver
    }

    /// The path of each request that arrived, in the order of arrival.
    var requestPaths: [String] {
        paths.withLock { $0 }
    }

    /// Stops the accept loop, which then closes the listening socket.
    ///
    /// A connection that is open stays open until its client closes it. The
    /// client is the `acp-client` process, which has ended when a test calls
    /// this.
    func stop() {
        var byte = Self.wakeByte
        _ = write(wakeWriter, &byte, MemoryLayout<UInt8>.size)
        close(wakeWriter)
    }

    /// Accepts each connection and serves it on a thread of its own, until
    /// ``stop()`` wakes the loop.
    private func acceptConnections() {
        defer {
            close(listener)
            close(wakeReader)
        }
        while waitForConnection() {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var enabled: Int32 = 1
            setsockopt(
                connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)
            )
            Thread.detachNewThread { self.serve(connection) }
        }
    }

    /// Waits until a connection arrives or ``stop()`` writes to the pipe.
    ///
    /// - Returns: `true` when a connection is ready to accept, and `false`
    ///   when the loop must stop.
    private func waitForConnection() -> Bool {
        var descriptors = [
            pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeReader, events: Int16(POLLIN), revents: 0),
        ]
        var ready = poll(&descriptors, nfds_t(descriptors.count), Self.noPollTimeout)
        while ready < 0 && errno == EINTR {
            ready = poll(&descriptors, nfds_t(descriptors.count), Self.noPollTimeout)
        }
        let listenerIsReady = descriptors[0].revents & Int16(POLLIN) != 0
        let stopWasAsked = descriptors[1].revents != 0
        return ready > 0 && listenerIsReady && !stopWasAsked
    }

    /// Reads each request on one connection, records its path, and answers it
    /// as ``reply`` says, until the client closes the connection.
    ///
    /// - Parameter connection: The accepted connection. This function closes
    ///   it.
    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var pending: [UInt8] = []
        while let path = Self.readRequest(from: connection, into: &pending) {
            paths.withLock { $0.append(path) }
            if reply == .success {
                Self.sendSuccess(to: connection)
            }
        }
    }

    /// Reads one whole request, head and body, from a connection.
    ///
    /// - Parameters:
    ///   - connection: The connection to read.
    ///   - pending: The bytes read before and not used yet. The bytes of this
    ///     request are taken out of it.
    /// - Returns: The path of the request line, or `nil` when the client closed
    ///   the connection before the request was whole.
    private static func readRequest(from connection: Int32, into pending: inout [UInt8]) -> String? {
        guard let headRange = readHead(from: connection, into: &pending) else { return nil }
        let head = String(decoding: pending[..<headRange.lowerBound], as: UTF8.self)
        let requestEnd = headRange.upperBound + contentLength(in: head)
        while pending.count < requestEnd {
            guard receive(from: connection, into: &pending) else { return nil }
        }
        pending.removeSubrange(..<requestEnd)
        return path(in: head)
    }

    /// Reads from a connection until the buffer holds the whole head of a
    /// request.
    ///
    /// - Parameters:
    ///   - connection: The connection to read.
    ///   - pending: The buffer that gets the bytes.
    /// - Returns: The range of ``headTerminator`` in `pending`, or `nil` when
    ///   the client closed the connection first.
    private static func readHead(from connection: Int32, into pending: inout [UInt8]) -> Range<Int>? {
        while true {
            if let terminator = pending.firstRange(of: headTerminator) {
                return terminator
            }
            guard receive(from: connection, into: &pending) else { return nil }
        }
    }

    /// Reads the bytes that are ready on a connection, and waits for them when
    /// none are ready.
    ///
    /// - Parameters:
    ///   - connection: The connection to read.
    ///   - pending: The buffer that gets the bytes.
    /// - Returns: `false` when the client closed the connection or the read
    ///   failed.
    private static func receive(from connection: Int32, into pending: inout [UInt8]) -> Bool {
        var chunk = [UInt8](repeating: 0, count: readChunkSize)
        let count = recv(connection, &chunk, chunk.count, 0)
        guard count > 0 else { return false }
        pending.append(contentsOf: chunk[..<count])
        return true
    }

    /// Returns the value of the `Content-Length` field of a request head.
    ///
    /// - Parameter head: The head of the request, without its terminator.
    /// - Returns: The length of the body, or `0` when the head gives none.
    private static func contentLength(in head: String) -> Int {
        let values = head.split(separator: lineBreak).dropFirst().compactMap { line -> Int? in
            guard let separator = line.firstIndex(of: fieldSeparator),
                line[..<separator].lowercased() == contentLengthField
            else { return nil }
            return Int(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
        }
        return values.first ?? 0
    }

    /// Returns the path of the request line of a request head.
    ///
    /// - Parameter head: The head of the request, without its terminator.
    /// - Returns: The second part of the request line, or an empty string when
    ///   the request line has no second part.
    private static func path(in head: String) -> String {
        let requestLine = head.split(separator: lineBreak).first ?? ""
        return requestLine.split(separator: requestLineSeparator).dropFirst().first.map(String.init) ?? ""
    }

    /// Writes ``successResponse`` to a connection.
    ///
    /// - Parameter connection: The connection to answer on.
    private static func sendSuccess(to connection: Int32) {
        successResponse.withUnsafeBytes { bytes in
            _ = send(connection, bytes.baseAddress, bytes.count, 0)
        }
    }
}
