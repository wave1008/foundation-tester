// ブリッジを建て直すと token が変わり、init で固定した値のままの BridgeClient は以後すべて 401 で
// 「接続断」とも扱われず戻れなかった(実機 iPhone 13・§19.3)。401 を受けたら台帳を読み直して
// 1 回だけ撃ち直す(`BridgeClient.tokenReloader`)。読み直しても同じ値なら名指しで断る(永久に回らない)。

import XCTest
@testable import FTBridgeClient
import FTCore

/// token ヘッダを見て 401 / 200 を返すループバックの偽ブリッジ(/status だけ)
private final class TokenCheckingBridge {
    private var serverFD: Int32 = -1
    let port: UInt16
    let accepted: String
    private let lock = NSLock()
    private(set) var seenTokens: [String] = []

    init(accepted: String) throws {
        self.accepted = accepted
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw Failure.bind(errno) }
        guard listen(fd, 8) == 0 else { close(fd); throw Failure.listen(errno) }
        var bound2 = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound2) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: bound2.sin_port)
        serverFD = fd
        Thread.detachNewThread { [weak self, fd] in
            while true {
                var ca = sockaddr()
                var cl = socklen_t(MemoryLayout<sockaddr>.size)
                let c = accept(fd, &ca, &cl)
                if c < 0 { break }
                self?.serve(c)
            }
        }
    }

    private func serve(_ c: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = read(c, &buffer, buffer.count)
        let request = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
        let header = BridgeAPI.bridgeTokenHeader.lowercased() + ":"
        let token = request.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix(header) }
            .map { String($0.dropFirst(header.count)).trimmingCharacters(in: .whitespaces) } ?? ""
        lock.lock(); seenTokens.append(token); lock.unlock()
        let body: String
        let status: String
        if token == accepted {
            status = "200 OK"
            body = #"{"ready":true,"device":"fake","osVersion":"1","sessionBundleID":null}"#
        } else {
            status = "401 Unauthorized"
            body = #"{"error":"unauthorized"}"#
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        _ = response.withCString { write(c, $0, strlen($0)) }
        close(c)
    }

    func stop() { if serverFD >= 0 { close(serverFD); serverFD = -1 } }
    deinit { stop() }
    enum Failure: Error { case socket(Int32), bind(Int32), listen(Int32) }
}

final class BridgeClientTokenReloadTests: XCTestCase {

    /// 建て直し後の新しい token を台帳から読み直し、1 回だけ撃ち直して通す
    func testA401ReloadsTheTokenAndRetriesOnce() async throws {
        let bridge = try TokenCheckingBridge(accepted: "new-token")
        defer { bridge.stop() }
        let client = BridgeClient(port: bridge.port, timeoutSeconds: 10, token: "old-token")
        var reloads = 0
        client.tokenReloader = { reloads += 1; return "new-token" }

        let status = try await client.status()

        XCTAssertTrue(status.ready)
        XCTAssertEqual(bridge.seenTokens, ["old-token", "new-token"])
        XCTAssertEqual(reloads, 1)
        // 以後は新しい token で撃つ(毎回 401 → 読み直し、にはならない)
        _ = try await client.status()
        XCTAssertEqual(bridge.seenTokens, ["old-token", "new-token", "new-token"])
        XCTAssertEqual(reloads, 1)
    }

    /// 読み直しても同じ値なら撃ち直さず、名指しで断る(台帳が古い・別のブリッジのもの)
    func testA401WithAnUnchangedLedgerFailsWithGuidance() async throws {
        let bridge = try TokenCheckingBridge(accepted: "new-token")
        defer { bridge.stop() }
        let client = BridgeClient(port: bridge.port, timeoutSeconds: 10, token: "old-token")
        client.tokenReloader = { "old-token" }

        do {
            _ = try await client.status()
            XCTFail("401 のまま通してはいけない")
        } catch let error as DriverError {
            guard case .badResponse(let status, let body) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("rejected this session's token"), body)
            XCTAssertTrue(body.contains("bridge up --port \(bridge.port)"), body)
        }
        XCTAssertEqual(bridge.seenTokens, ["old-token"], "同じ値では撃ち直さない")
    }
}
