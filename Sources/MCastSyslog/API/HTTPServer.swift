import Foundation
import Network

/// A parsed HTTP request. Only what a read-only API needs: there is no body,
/// because there is no endpoint that takes one.
public struct HTTPRequest {
    public let method: String
    public let path: String
    public let query: [String: [String]]
    public let headers: [String: String]
    public let httpVersion: String

    /// The last value given for a parameter, which is what a repeated query
    /// string usually means.
    public func first(_ name: String) -> String? { query[name]?.last }

    /// A parameter that may be repeated (`?host=a&host=b`) or comma-separated
    /// (`?host=a,b`). Both spellings are accepted because both get typed.
    public func list(_ name: String) -> [String] {
        (query[name] ?? [])
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func int(_ name: String) -> Int? { first(name).flatMap(Int.init) }

    public func bool(_ name: String) -> Bool? {
        guard let value = first(name)?.lowercased() else { return nil }
        if ["1", "true", "yes", "on"].contains(value) { return true }
        if ["0", "false", "no", "off"].contains(value) { return false }
        return nil
    }
}

public struct HTTPResponse {
    public var status: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, reason: String = "OK",
                headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public static func json(_ object: Any, status: Int = 200, reason: String = "OK") -> HTTPResponse {
        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"error":"could not encode the response"}"#.utf8)
        return HTTPResponse(
            status: status, reason: reason,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data)
    }

    public static func error(_ status: Int, _ reason: String, _ message: String) -> HTTPResponse {
        json(["error": message, "status": status], status: status, reason: reason)
    }

    public static func html(_ text: String) -> HTTPResponse {
        HTTPResponse(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(text.utf8))
    }

    public static func text(_ text: String) -> HTTPResponse {
        HTTPResponse(headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }
}

/// What a route can return: a finished response, or a long-lived stream that
/// keeps the connection open and pushes to it.
public enum RouteResult {
    case response(HTTPResponse)
    case eventStream(EventStreamHandle)
}

/// A held-open Server-Sent Events connection.
public final class EventStreamHandle: @unchecked Sendable {
    fileprivate var write: ((Data) -> Void)?
    fileprivate var closed = false
    private let lock = NSLock()
    /// Called when the client goes away, so the router can unsubscribe.
    public var onClose: (() -> Void)?

    public func send(event: String, json: Any) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        var frame = "event: \(event)\ndata: "
        frame += String(decoding: data, as: UTF8.self)
        frame += "\n\n"
        send(raw: frame)
    }

    public func send(raw: String) {
        lock.lock()
        let writer = closed ? nil : write
        lock.unlock()
        writer?(Data(raw.utf8))
    }

    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        onClose?()
    }

    fileprivate func attach(_ writer: @escaping (Data) -> Void) {
        lock.lock(); write = writer; lock.unlock()
    }

    /// True once the client has gone away, so a broadcaster can drop it
    /// instead of writing into a socket nobody is reading.
    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }
}

/// A small HTTP/1.1 server, for serving the stored log over REST.
///
/// It binds to the loopback address by default. That is the safe posture and
/// the one to keep: this serves everything the viewer has heard from every node
/// in the fleet, so exposing it on a network is a decision to be made
/// deliberately rather than by omission.
///
/// It is read-only in the strongest sense available: only GET and HEAD are
/// routed at all, and nothing it can reach has a path back to a node.
public final class HTTPServer: @unchecked Sendable {

    public struct Configuration: Equatable, Sendable {
        public var port: UInt16
        /// When false, the listener binds to 127.0.0.1 and nothing off this
        /// machine can reach it.
        public var allowRemote: Bool

        public init(port: UInt16 = 8514, allowRemote: Bool = false) {
            self.port = port
            self.allowRemote = allowRemote
        }
    }

    public private(set) var configuration = Configuration()
    public var route: ((HTTPRequest) -> RouteResult)?
    public var onStateChange: ((String?) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lo.stormcos.mcastsyslog.http", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var lastError: String?

    public init() {}

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public var error: String? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    public var baseURL: String {
        let host = configuration.allowRemote ? Host.current().localizedName ?? "0.0.0.0" : "127.0.0.1"
        return "http://\(host):\(configuration.port)"
    }

    public func start(_ configuration: Configuration) {
        stop()
        self.configuration = configuration

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if !configuration.allowRemote {
            // Bound to loopback, so nothing off this machine can reach it.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                         port: NWEndpoint.Port(rawValue: configuration.port)!)
        }

        do {
            // When `requiredLocalEndpoint` is set it already carries the port,
            // and passing `on:` as well makes the listener fail to come up.
            let listener = configuration.allowRemote
                ? try NWListener(using: parameters,
                                 on: NWEndpoint.Port(rawValue: configuration.port) ?? .any)
                : try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.setState(running: true, error: nil)
                case .failed(let error):
                    self.setState(running: false, error: "\(error)")
                case .cancelled:
                    self.setState(running: false, error: nil)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            setState(running: false, error: "\(error)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        setState(running: false, error: lastError)
    }

    private func setState(running: Bool, error: String?) {
        lock.lock()
        self.running = running
        self.lastError = error
        lock.unlock()
        onStateChange?(error)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// HTTP requests here have no body, so the whole request is whatever
    /// arrives before the blank line.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            guard error == nil else { connection.cancel(); return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            // A request header this large is not a request this server serves.
            guard buffer.count <= 64 * 1024 else {
                self.finish(connection, with: .error(431, "Request Header Fields Too Large",
                                                     "the request header is too large"))
                return
            }

            if let headerEnd = Self.headerEnd(in: buffer) {
                let head = String(decoding: buffer[..<headerEnd], as: UTF8.self)
                self.handle(head, on: connection)
                return
            }

            if isComplete { connection.cancel(); return }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private static func headerEnd(in data: Data) -> Data.Index? {
        let pattern = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: pattern) else {
            // Tolerate bare LF, which hand-typed requests and some tools send.
            guard let lf = data.range(of: Data("\n\n".utf8)) else { return nil }
            return lf.lowerBound
        }
        return range.lowerBound
    }

    private func handle(_ head: String, on connection: NWConnection) {
        guard let request = Self.parse(head) else {
            finish(connection, with: .error(400, "Bad Request", "could not parse the request"))
            return
        }

        guard request.method == "GET" || request.method == "HEAD" else {
            var response = HTTPResponse.error(405, "Method Not Allowed",
                "this API is read-only — only GET and HEAD are served")
            response.headers["Allow"] = "GET, HEAD"
            finish(connection, with: response)
            return
        }

        switch route?(request) ?? .response(.error(503, "Service Unavailable", "no router attached")) {
        case .response(var response):
            if request.method == "HEAD" { response.body = Data() }
            finish(connection, with: response, keepAlive: Self.wantsKeepAlive(request))
        case .eventStream(let stream):
            open(stream, on: connection)
        }
    }

    private static func wantsKeepAlive(_ request: HTTPRequest) -> Bool {
        let connectionHeader = request.headers["connection"]?.lowercased()
        if connectionHeader == "close" { return false }
        if request.httpVersion == "HTTP/1.0" { return connectionHeader == "keep-alive" }
        return true
    }

    private func finish(_ connection: NWConnection, with response: HTTPResponse, keepAlive: Bool = false) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        // This server exists to be read by curl and scripts. It sends no CORS
        // header on purpose: with one, any page the user happened to be
        // visiting could read the whole fleet's logs out of their browser.
        head += "X-Content-Type-Options: nosniff\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            if keepAlive {
                self?.receive(on: connection, buffer: Data())
            } else {
                connection.cancel()
            }
        })
    }

    /// Server-Sent Events: headers, then the connection stays open and the
    /// router pushes to it until the client goes away.
    private func open(_ stream: EventStreamHandle, on connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream; charset=utf-8\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: keep-alive\r\n"
        head += "X-Content-Type-Options: nosniff\r\n\r\n"

        stream.attach { [weak connection] data in
            guard let connection else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: stream.close()
            default: break
            }
        }

        connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
            if error != nil { stream.close(); connection.cancel(); return }
            stream.send(raw: ": listening\n\n")
        })

        // A client that walks away leaves no signal on a stream it never writes
        // to, so notice the close by reading.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
            if isComplete || error != nil {
                stream.close()
                connection.cancel()
            }
        }

        // Keep NAT and impatient proxies from cutting an idle stream, and give
        // the client a way to notice the server is gone.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.heartbeat(stream, on: connection)
        }
    }

    private func heartbeat(_ stream: EventStreamHandle, on connection: NWConnection) {
        guard !stream.isClosed else { connection.cancel(); return }
        stream.send(raw: ": keep-alive\n\n")
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.heartbeat(stream, on: connection)
        }
    }

    // MARK: - Parsing

    static func parse(_ head: String) -> HTTPRequest? {
        var lines = head.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n",
                                                                            omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }

        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        let version = requestLine.count > 2 ? String(requestLine[2]) : "HTTP/1.1"

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = percentDecode(String(parts[0]))
        var query: [String: [String]] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&", omittingEmptySubsequences: true) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = percentDecode(String(kv[0]))
                let value = kv.count > 1 ? percentDecode(String(kv[1])) : ""
                guard !name.isEmpty else { continue }
                query[name, default: []].append(value)
            }
        }

        return HTTPRequest(method: method, path: path, query: query,
                           headers: headers, httpVersion: version)
    }

    /// `+` means space in a query string, which `removingPercentEncoding` alone
    /// does not know.
    static func percentDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}
