import Foundation
import Network

/// A loopback HTTP server for page tests. It listens on 127.0.0.1 only, so
/// tests need no fixture server and macOS asks nothing; `localhost` reaches it
/// too, as a different site. Each request gets one response, then the
/// connection closes.
final class TestHTTPServer: @unchecked Sendable {
    struct Response {
        var status = 200
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        var body = Data()

        static func html(_ text: String) -> Response { Response(body: Data(text.utf8)) }

        static func script(_ text: String) -> Response {
            Response(headers: ["Content-Type": "text/javascript"], body: Data(text.utf8))
        }

        static func redirect(to url: URL) -> Response {
            Response(status: 302, headers: ["Location": url.absoluteString], body: Data())
        }
    }

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestHTTPServer")
    private let lock = NSLock()
    private var routes: [String: Response] = [:]

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> TestHTTPServer {
        let listener = try loopbackListener()
        // Connections wait in the listener until the server takes them.
        let accepted = Accepted()
        listener.newConnectionHandler = { accepted.take($0) }
        let server = TestHTTPServer(listener: listener, port: try await ready(listener))
        accepted.serve { [weak server] connection in server?.serve(connection) ?? connection.cancel() }
        return server
    }

    /// An address nothing listens on, for loads that must fail.
    static func closedURL() async throws -> URL {
        let listener = try loopbackListener()
        listener.newConnectionHandler = { $0.cancel() }
        let port = try await ready(listener)
        listener.cancel()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    func url(_ path: String, host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    /// Answers requests for `path`, without its query, with `response`.
    func route(_ path: String, _ response: Response) {
        lock.withLock { routes[path] = response }
    }

    func stop() { listener.cancel() }

    private static func loopbackListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        return try NWListener(using: parameters, on: .any)
    }

    /// A listener fails to start without a connection handler.
    private static func ready(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "TestHTTPServer.listener"))
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            let response = self.lock.withLock { self.routes[path] } ?? Response(status: 404, body: Data("Not found".utf8))
            connection.send(content: Self.encode(response), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func encode(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}

/// Holds connections that arrive before the server can serve them.
private final class Accepted: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [NWConnection] = []
    private var handler: ((NWConnection) -> Void)?

    func take(_ connection: NWConnection) {
        let handler = lock.withLock { () -> ((NWConnection) -> Void)? in
            if self.handler == nil { waiting.append(connection) }
            return self.handler
        }
        handler?(connection)
    }

    func serve(_ handler: @escaping (NWConnection) -> Void) {
        let waiting = lock.withLock { () -> [NWConnection] in
            self.handler = handler
            defer { self.waiting = [] }
            return self.waiting
        }
        waiting.forEach(handler)
    }
}

/// Resumes a continuation at most once from a callback that can repeat.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
