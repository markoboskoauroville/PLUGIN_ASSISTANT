import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 only (Network.framework). First free port from `from` upward.
/// CORS is answered for chrome-extension:// origins (and the classroom page); everything else gets no CORS header.
final class Http: @unchecked Sendable {
    var onReady: ((UInt16) -> Void)?
    var handler: ((String, String, Data) async -> (Int, Data))?
    private var listener: NWListener?

    func start(_ p: UInt16, tries: Int = 16) {
        guard tries > 0, let port = NWEndpoint.Port(rawValue: p) else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: self?.onReady?(p)
                case .failed: l.cancel(); self?.start(p + 1, tries: tries - 1)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.start(queue: .global())
            listener = l
        } catch { start(p + 1, tries: tries - 1) }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .global())
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self = self else { c.cancel(); return }
            var buf = acc
            if let d = data { buf.append(d) }
            if let (m, p, body, origin) = Http.parse(buf) {
                if m == "OPTIONS" { Http.send(c, 204, Data(), origin); return }
                Task {
                    let (code, out) = await self.handler?(m, p, body) ?? (500, Data())
                    Http.send(c, code, out, origin)
                }
            } else if done || err != nil { c.cancel() }
            else { self.receive(c, buf) }
        }
    }

    static func parse(_ buf: Data) -> (String, String, Data, String)? {
        guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var len = 0
        var origin = ""
        for l in lines.dropFirst() {
            let low = l.lowercased()
            if low.hasPrefix("content-length:") { len = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0 }
            if low.hasPrefix("origin:") { origin = l.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        }
        let body = buf[r.upperBound...]
        if body.count < len { return nil }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        return (String(parts[0]), path, Data(body.prefix(len)), origin)
    }

    static func send(_ c: NWConnection, _ code: Int, _ body: Data, _ origin: String) {
        let text = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 404: "Not Found", 409: "Conflict"][code] ?? "Error"
        var cors = ""
        if origin.hasPrefix("chrome-extension://") || origin == "https://mpa-academy.pages.dev" {
            cors = "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\n"
        }
        var out = Data("HTTP/1.1 \(code) \(text)\r\nContent-Type: application/json; charset=utf-8\r\n\(cors)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
