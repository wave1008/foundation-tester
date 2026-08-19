// POST /swipe の `edge`(端まで送るのが目的)がワイヤに載ることの固定。
// in-app ブリッジはこのフラグ1つで「ページ送り」と「端まで一度に寄せる」を分ける
// (InAppBridge.handleSwipe → scrollToEdge)。ここが落ちると **長文が黙って従来速度に戻る**
// —— 結果は正しいままなので、テストか実測でしか気付けない。
//
// 同時に **ジェスチャ目的・探索目的では立たない**ことも固定する: 立ってしまうと
// `scrollTo` の探索が1回で端まで飛び、途中の要素を全部飛び越す。

import XCTest
@testable import FTBridgeClient
import FTCore

/// 受けたリクエストのパスと本文を記録し、すべて 200 `{"ok":true}` を返す最小 HTTP スタブ。
private final class BodyRecordingStubServer {
    private var serverFD: Int32 = -1
    let port: UInt16
    private let lock = NSLock()
    private var _bodies: [String: String] = [:]
    /// パス("POST /swipe")→ 最後に受けた本文
    func body(for path: String) -> String? { lock.lock(); defer { lock.unlock() }; return _bodies[path] }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // エフェメラルポート(固定ポートは並走テストとぶつかる)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw Failure.bind(errno) }
        guard listen(fd, 8) == 0 else { close(fd); throw Failure.listen(errno) }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.port = UInt16(bigEndian: assigned.sin_port)
        self.serverFD = fd

        Thread.detachNewThread { [weak self, fd] in
            while true {
                var ca = sockaddr()
                var cl = socklen_t(MemoryLayout<sockaddr>.size)
                let c = accept(fd, &ca, &cl)
                if c < 0 { break }  // serverFD の close で脱出
                // **1回の read で本文まで来るとは限らない**(URLSession はヘッダと本文を別の
                // セグメントで送る)。Content-Length ぶん読み切るまで続ける —— ここを縮めると
                // 本文が空のまま「JSON が壊れている」として落ちる
                var raw = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let n = read(c, &buffer, buffer.count)
                    if n <= 0 { break }
                    raw.append(contentsOf: buffer[0..<n])
                    guard let text = String(data: raw, encoding: .utf8),
                          let headerEnd = text.range(of: "\r\n\r\n") else { continue }
                    let header = String(text[text.startIndex..<headerEnd.lowerBound])
                    let length = header.components(separatedBy: "\r\n")
                        .first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    let body = String(text[headerEnd.upperBound...])
                    if body.utf8.count >= length {
                        let head = header.split(separator: " ")
                        if head.count >= 2 {
                            self?.lock.lock()
                            self?._bodies["\(head[0]) \(head[1])"] = body
                            self?.lock.unlock()
                        }
                        break
                    }
                }
                let body = #"{"ok":true}"#
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = response.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }
    }

    func stop() { if serverFD >= 0 { close(serverFD); serverFD = -1 } }
    deinit { stop() }

    enum Failure: Error { case socket(Int32), bind(Int32), listen(Int32) }
}

final class EdgeSwipeWireTests: XCTestCase {

    private func sentSwipe(intent: FTSwipeIntent) async throws -> SwipeRequest {
        let stub = try BodyRecordingStubServer()
        defer { stub.stop() }
        let client = BridgeClient(port: stub.port, interactionTimeout: 5, sessionTimeout: 5)
        try await client.swipe(.up, intent: intent, path: nil)
        guard let raw = stub.body(for: "POST /swipe"), let data = raw.data(using: .utf8) else {
            throw Failure.noBody
        }
        return try JSONDecoder().decode(SwipeRequest.self, from: data)
    }

    private enum Failure: Error { case noBody }

    func testEdgeIntentSetsEdgeOnTheWire() async throws {
        let request = try await sentSwipe(intent: .edge)
        XCTAssertEqual(request.edge, true,
                       "端送りで edge が立っていない: in-app は1ページずつ刻んだままになる")
        XCTAssertEqual(request.scroll, true, "スクロール目的の申告も併せて要る")
    }

    func testSearchAndGestureDoNotSetEdge() async throws {
        let search = try await sentSwipe(intent: .search)
        XCTAssertNil(search.edge,
                     "探索で edge が立つと1回で端まで飛び、途中の要素を全部飛び越す")
        let gesture = try await sentSwipe(intent: .gesture)
        XCTAssertNil(gesture.edge, "DSL の swipe(ジェスチャ目的)で edge が立っている")
    }
}
