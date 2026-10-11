import Foundation
import Network
import Security

/// Shared secret between the app and `stechuhr-hook`, stored in a file only the user can read.
/// Without it, any local process or web page could post fake events to the localhost endpoint.
public enum HookToken {
    public static func loadOrCreate(at url: URL = StechuhrPaths.hookToken) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("Stechuhr: kein Zufallsgenerator verfügbar")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    /// Constant-time comparison.
    static func matches(_ a: String?, _ b: String) -> Bool {
        guard let a, a.utf8.count == b.utf8.count else { return false }
        return zip(a.utf8, b.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Tiny HTTP endpoint on 127.0.0.1 that receives events from `stechuhr-hook`.
/// Accepts `POST /v1/claude-code/events` with one JSON event, and `GET /health`.
/// Every request needs the `X-Stechuhr-Token` header. Requests from browsers (with an `Origin` header)
/// or with a foreign `Host` (DNS rebinding) are rejected.
public final class HookServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "stechuhr.hookserver")
    private let onEvent: @Sendable (ClaudeEvent) -> Void
    private let token: String

    public init(token: String, onEvent: @escaping @Sendable (ClaudeEvent) -> Void) {
        self.token = token
        self.onEvent = onEvent
    }

    public func start(port: UInt16 = StechuhrPaths.hookPort) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() { listener?.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Don't let idle connections pile up.
        queue.asyncAfter(deadline: .now() + 5) { conn.cancel() }
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if buffer.count > 64 * 1024 { conn.cancel(); return }
            if let data { buffer.append(data) }
            if buffer.count > 64 * 1024 || error != nil { conn.cancel(); return }
            if let req = HTTPRequest.parse(buffer) {
                self.respond(conn, to: req)
            } else if done {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private func respond(_ conn: NWConnection, to req: HTTPRequest) {
        var status = "404 Not Found"
        let port = String(StechuhrPaths.hookPort)
        let hostOK = ["127.0.0.1:\(port)", "localhost:\(port)"].contains(req.headers["host"]?.lowercased() ?? "")
        if req.headers["origin"] != nil || !hostOK {
            status = "403 Forbidden"
        } else if !HookToken.matches(req.headers["x-stechuhr-token"], token) {
            status = "401 Unauthorized"
        } else if req.method == "GET" && req.path == "/health" {
            status = "200 OK"
        } else if req.method == "POST" && req.path == "/v1/claude-code/events" {
            if let event = try? ClaudeEvent.decode(req.body) {
                onEvent(event)
                status = "204 No Content"
            } else {
                status = "400 Bad Request"
            }
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    /// Lower-cased header names.
    var headers: [String: String] = [:]
    var body: Data

    /// Returns nil until the full request (headers + Content-Length body) is in the buffer.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                headers[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }
}

/// Reads events that the hook helper wrote to the fallback file while the app was not running.
public enum HookInbox {
    @discardableResult
    public static func drain(into db: Database, file: URL = StechuhrPaths.hookInbox) -> Int {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        // Move first so that hooks firing during the import write to a fresh file.
        if fm.fileExists(atPath: file.path) {
            try? fm.moveItem(at: file, to: dir.appendingPathComponent("claude-events.importing-\(UUID().uuidString).jsonl"))
        }
        // Also picks up files left over from an earlier, interrupted import.
        let claimed = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("claude-events.importing-") }
        var n = 0
        for url in claimed {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var count = 0
            do {
                try db.transaction {
                    for line in content.split(separator: "\n") where !line.isEmpty {
                        if let e = try? ClaudeEvent.decode(Data(line.utf8)) {
                            try db.insert(e)
                            count += 1
                        }
                    }
                }
                try? fm.removeItem(at: url)
                n += count
            } catch {
                continue // keep the file for the next attempt
            }
        }
        return n
    }
}
