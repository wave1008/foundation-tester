// SandboxProxy.swift
// サンドボックスの中のシナリオは外部へ直接繋げない(Seatbelt のアドレス条件はホストに `*` か
// `localhost` しか書けず、ドメイン名でも IP でも絞れない)。**構成ファイルの `allowedDomains` に
// 書いた宛先だけ**を、親が立てるこのプロキシ経由で通す。子には `HTTP(S)_PROXY` で場所を渡すので、
// 通るのはプロキシの設定を読むクライアントだけ(curl・環境変数を読む HTTP ライブラリ)。
// `URLSession` は環境変数のプロキシを読まない = シナリオ側で `connectionProxyDictionary` に渡す。
//
// 受けるのは `CONNECT host:port`(HTTPS)と絶対 URI の平文 HTTP(`GET http://host/…`)の2形。
// 名前の照合は**接続の前**に行い、解決は親が行う(子に名前解決をさせない)。
import Foundation
import Network

public enum SandboxDomainPolicy {
    /// `example.com` は完全一致、`*.example.com` は1段以上のサブドメイン(裸の `example.com` は含まない)。
    /// 大文字小文字は無視し、末尾のドットは落とす。IP アドレスの直書きも文字列として同じ規則で照合する
    public static func allows(host: String, patterns: [String]) -> Bool {
        let name = normalized(host)
        guard !name.isEmpty else { return false }
        return patterns.contains { pattern in
            let rule = normalized(pattern)
            if rule.hasPrefix("*.") {
                let suffix = String(rule.dropFirst(1))  // ".example.com"
                return name.count > suffix.count && name.hasSuffix(suffix)
            }
            return name == rule
        }
    }

    static func normalized(_ host: String) -> String {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// 構成ファイルに書ける形か(`*` 単独や途中のワイルドカードは受けない = 「全部通す」を書けなくする)
    public static func isValidPattern(_ pattern: String) -> Bool {
        let rule = normalized(pattern)
        let body = rule.hasPrefix("*.") ? String(rule.dropFirst(2)) : rule
        guard !body.isEmpty, !body.hasPrefix("."), !body.hasSuffix("."), !body.contains("..") else {
            return false
        }
        return body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == ":") }
    }

    /// 要求の1行目から宛先を取り出す。受けない形は nil
    static func target(requestLine: String) -> (host: String, port: UInt16, isConnect: Bool)? {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
        if parts[0].uppercased() == "CONNECT" {
            guard let (host, port) = splitHostPort(parts[1], defaultPort: 443) else { return nil }
            return (host, port, true)
        }
        guard let components = URLComponents(string: parts[1]), components.scheme?.lowercased() == "http",
              let host = components.host, !host.isEmpty else { return nil }
        return (host, UInt16(components.port ?? 80), false)
    }

    static func splitHostPort(_ authority: String, defaultPort: UInt16) -> (String, UInt16)? {
        if authority.hasPrefix("[") {  // [v6]:port
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
        switch pieces.count {
        case 1: return pieces[0].isEmpty ? nil : (String(pieces[0]), defaultPort)
        case 2:
            guard !pieces[0].isEmpty, let port = UInt16(pieces[1]) else { return nil }
            return (String(pieces[0]), port)
        default: return nil
        }
    }
}

// @unchecked: 可変は `port` だけで、init の中(待受の準備完了を待つ間)にしか書かない。他は不変
public final class SandboxProxy: @unchecked Sendable {
    /// 待受が始まるまで 0(init が返った後は確定)
    public private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let patterns: [String]
    private let queue = DispatchQueue(label: "fleetest.sandbox-proxy", attributes: .concurrent)

    /// 要求ヘッダの上限(バイト)。これを超えても空行が来なければ断る(無限に溜めない)
    static let maxHeaderBytes = 64 * 1024

    public init(allowedDomains: [String]) throws {
        patterns = allowedDomains
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        ready.wait()
        guard let bound = listener.port?.rawValue, bound != 0 else {
            listener.cancel()
            throw POSIXError(.EADDRNOTAVAIL)
        }
        port = bound
    }

    public func stop() { listener.cancel() }

    /// 子へ渡す環境変数(大文字と小文字の両方。読むクライアントで綴りが割れている)
    public var environment: [String: String] {
        let url = "http://127.0.0.1:\(port)"
        return ["HTTP_PROXY": url, "HTTPS_PROXY": url, "http_proxy": url, "https_proxy": url,
                "ALL_PROXY": url, "all_proxy": url, "NO_PROXY": "localhost,127.0.0.1,::1",
                "no_proxy": "localhost,127.0.0.1,::1"]
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        readHead(client, buffer: Data())
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return client.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.route(client, head: buffer[..<end.lowerBound], raw: buffer, bodyStart: end.upperBound)
            } else if error != nil || isComplete || buffer.count > Self.maxHeaderBytes {
                self.refuse(client, status: "400 Bad Request", message: "malformed proxy request")
            } else {
                self.readHead(client, buffer: buffer)
            }
        }
    }

    private func route(_ client: NWConnection, head: Data, raw: Data, bodyStart: Data.Index) {
        let text = String(decoding: head, as: UTF8.self)
        let requestLine = text.components(separatedBy: "\r\n").first ?? ""
        guard let target = SandboxDomainPolicy.target(requestLine: requestLine) else {
            return refuse(client, status: "400 Bad Request", message: "unsupported proxy request")
        }
        guard SandboxDomainPolicy.allows(host: target.host, patterns: patterns) else {
            return refuse(client, status: "403 Forbidden",
                          message: "\(target.host) is not in allowedDomains of the sandbox configuration")
        }
        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            return refuse(client, status: "400 Bad Request", message: "bad port")
        }
        let upstream = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                upstream.stateUpdateHandler = nil
                if target.isConnect {
                    let ok = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                    client.send(content: ok, completion: .contentProcessed { _ in
                        // CONNECT の空行より後に既に届いていたぶん(TLS の ClientHello)を落とさない
                        let early = raw[bodyStart...]
                        if !early.isEmpty {
                            upstream.send(content: early, completion: .contentProcessed { _ in })
                        }
                        self.pipe(client, upstream)
                        self.pipe(upstream, client)
                    })
                } else {
                    upstream.send(content: raw, completion: .contentProcessed { _ in
                        self.pipe(client, upstream)
                        self.pipe(upstream, client)
                    })
                }
            case .failed, .cancelled:
                upstream.stateUpdateHandler = nil
                self.refuse(client, status: "502 Bad Gateway", message: "cannot reach \(target.host)")
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    private func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            let owner = self
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || isComplete || error != nil {
                        from.cancel(); to.cancel()
                    } else {
                        owner?.pipe(from, to)
                    }
                })
            } else {
                from.cancel(); to.cancel()
            }
        }
    }

    private func refuse(_ client: NWConnection, status: String, message: String) {
        let body = "fleetest sandbox: \(message)\n"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + body
        client.send(content: Data(response.utf8), completion: .contentProcessed { _ in client.cancel() })
    }
}
