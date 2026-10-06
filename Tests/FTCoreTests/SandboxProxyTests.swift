// 許可ドメインのプロキシ。名前の照合を誤ると「書いていない宛先へ出られる」か「書いた宛先へ出られない」。

import XCTest
@testable import FTCore

final class SandboxDomainPolicyTests: XCTestCase {

    func testExactAndWildcardMatching() {
        let patterns = ["api.example.com", "*.cdn.example.net"]
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "api.example.com", port: 443, patterns: patterns))
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "API.Example.COM.", port: 443, patterns: patterns))
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "a.cdn.example.net", port: 443, patterns: patterns))
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "a.b.cdn.example.net", port: 443, patterns: patterns))
        // ワイルドカードは裸のドメインを含まない・接尾辞の一致は区切りを跨がない
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "cdn.example.net", port: 443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "evilcdn.example.net", port: 443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "example.com", port: 443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "api.example.com.evil.org", port: 443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "xapi.example.com", port: 443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "", port: 443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "api.example.com", port: 443, patterns: []))
    }

    /// 「全部通す」を書けない(`*` 単独・途中のワイルドカード)
    func testPatternsThatWouldAllowEverythingAreInvalid() {
        for bad in ["*", "*.", "", ".", "*.*", "a.*.com", "exa mple.com", "example.com/path",
                    "https://example.com", ".example.com", "example..com"] {
            XCTAssertFalse(SandboxDomainPolicy.isValidPattern(bad), bad)
        }
        for good in ["example.com", "*.example.com", "localhost", "api-1.example.co.jp", "10.0.0.5"] {
            XCTAssertTrue(SandboxDomainPolicy.isValidPattern(good), good)
        }
    }

    /// ポートを書いた行はそのポートだけ・書かない行は全ポート(CONNECT は任意の TCP を中継する)
    func testPortRestrictsOnlyTheEntriesThatNameIt() {
        let patterns = ["api.example.com:443", "*.cdn.example.net:8443", "files.example.org", "[2001:db8::1]:443", "2001:db8::2"]
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "api.example.com", port: 443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "api.example.com", port: 5432, patterns: patterns))
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "a.cdn.example.net", port: 8443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "a.cdn.example.net", port: 443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "cdn.example.net", port: 8443, patterns: patterns))
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "files.example.org", port: 22, patterns: patterns))
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "files.example.org", port: 443, patterns: patterns))
        // IPv6: 角括弧つきはポートを持つ・角括弧なしは全ポート(末尾の `:2` をポートと読まない)
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "2001:db8::1", port: 443, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "2001:db8::1", port: 80, patterns: patterns))
        XCTAssertTrue(SandboxDomainPolicy.allows(host: "2001:db8::2", port: 80, patterns: patterns))
        XCTAssertFalse(SandboxDomainPolicy.allows(host: "2001:db8:", port: 2, patterns: patterns))
    }

    func testPortSyntax() {
        for bad in ["example.com:", "example.com:0", "example.com:65536", "example.com:abc", "example.com:443-8443",
                    "example.com:*", "*:443", "example.com:+443", "[example.com]:443", "[::1]443", "[::1]:", "[::1"] {
            XCTAssertFalse(SandboxDomainPolicy.isValidPattern(bad), bad)
        }
        for good in ["example.com:443", "*.example.com:8443", "10.0.0.5:8080", "[::1]:443", "[2001:db8::1]",
                     "2001:db8::1", "example.com:65535", "example.com:1"] {
            XCTAssertTrue(SandboxDomainPolicy.isValidPattern(good), good)
        }
    }

    func testRequestLineParsing() throws {
        let connect = try XCTUnwrap(SandboxDomainPolicy.target(requestLine: "CONNECT example.com:8443 HTTP/1.1"))
        XCTAssertEqual(connect.host, "example.com")
        XCTAssertEqual(connect.port, 8443)
        XCTAssertTrue(connect.isConnect)
        let plain = try XCTUnwrap(SandboxDomainPolicy.target(requestLine: "GET http://example.com/a?b=1 HTTP/1.1"))
        XCTAssertEqual(plain.host, "example.com")
        XCTAssertEqual(plain.port, 80)
        XCTAssertFalse(plain.isConnect)
        XCTAssertEqual(SandboxDomainPolicy.target(requestLine: "CONNECT [::1]:443 HTTP/1.1")?.host, "::1")
        // 相対 URI(プロキシ宛でない要求)・https の平文・壊れた形は受けない
        XCTAssertNil(SandboxDomainPolicy.target(requestLine: "GET /path HTTP/1.1"))
        XCTAssertNil(SandboxDomainPolicy.target(requestLine: "GET https://example.com/ HTTP/1.1"))
        XCTAssertNil(SandboxDomainPolicy.target(requestLine: "CONNECT example.com:notaport HTTP/1.1"))
        XCTAssertNil(SandboxDomainPolicy.target(requestLine: "CONNECT a:1:2 HTTP/1.1"))
        XCTAssertNil(SandboxDomainPolicy.target(requestLine: "garbage"))
    }
}

/// 実際に待ち受けて、許可した名前は上流へ繋がり、それ以外は 403 で閉じること。
/// 上流はこの Mac の中の待受(`localhost`)なので、ネットワークに出ない
final class SandboxProxyTests: XCTestCase {

    /// プロキシへ1行目を送り、返ってきた先頭(と、続けて送った内容への応答)を読む
    private func exchange(port: UInt16, request: String, thenSend: String? = nil) throws -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        func send(_ text: String) { _ = text.withCString { write(descriptor, $0, strlen($0)) } }
        func receive() -> String {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            return count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        }
        send(request)
        var response = receive()
        if let thenSend {
            send(thenSend)
            response += receive()
        }
        return response
    }

    func testAllowedHostIsTunnelledAndOthersAreForbidden() throws {
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let proxy = try SandboxProxy(allowedDomains: ["localhost"])
        defer { proxy.stop() }
        XCTAssertNotEqual(proxy.port, 0)

        let tunnelled = try exchange(
            port: proxy.port, request: "CONNECT localhost:\(upstream.port) HTTP/1.1\r\nHost: x\r\n\r\n",
            thenSend: "ping\n")
        XCTAssertTrue(tunnelled.hasPrefix("HTTP/1.1 200"), tunnelled)
        XCTAssertTrue(tunnelled.contains("echo:ping"), tunnelled)

        // 同じ待受でも、名前が一覧に無ければ繋がない(IP の直書きも名前として照合する)
        let byAddress = try exchange(
            port: proxy.port, request: "CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\r\n")
        XCTAssertTrue(byAddress.hasPrefix("HTTP/1.1 403"), byAddress)
        XCTAssertTrue(byAddress.contains("allowedDomains"), byAddress)
        let other = try exchange(port: proxy.port, request: "CONNECT example.org:443 HTTP/1.1\r\n\r\n")
        XCTAssertTrue(other.hasPrefix("HTTP/1.1 403"), other)
        let relative = try exchange(port: proxy.port, request: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertTrue(relative.hasPrefix("HTTP/1.1 400"), relative)
    }

    func testPortRestrictedEntryTunnelsOnlyThatPort() throws {
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let proxy = try SandboxProxy(allowedDomains: ["localhost:\(upstream.port)"])
        defer { proxy.stop() }
        let tunnelled = try exchange(
            port: proxy.port, request: "CONNECT localhost:\(upstream.port) HTTP/1.1\r\n\r\n", thenSend: "ping\n")
        XCTAssertTrue(tunnelled.contains("echo:ping"), tunnelled)
        let otherPort = upstream.port == 65535 ? upstream.port - 1 : upstream.port + 1
        let refused = try exchange(port: proxy.port, request: "CONNECT localhost:\(otherPort) HTTP/1.1\r\n\r\n")
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 403"), refused)
        XCTAssertTrue(refused.contains("localhost:\(otherPort)"), refused)
    }

    func testEnvironmentPointsEveryProxyVariableAtTheListener() throws {
        let proxy = try SandboxProxy(allowedDomains: ["example.com"])
        defer { proxy.stop() }
        let url = "http://127.0.0.1:\(proxy.port)"
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"] {
            XCTAssertEqual(proxy.environment[key], url, key)
        }
    }
}

/// 受け取った行に `echo:` を付けて返すだけの TCP サーバ(127.0.0.1)
private final class EchoServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard fd >= 0, bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        descriptor = fd
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [fd] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 1024)
                let count = read(client, &buffer, buffer.count)
                if count > 0 {
                    let reply = Array("echo:".utf8) + buffer[..<count]
                    _ = reply.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                }
                close(client)
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }
}
