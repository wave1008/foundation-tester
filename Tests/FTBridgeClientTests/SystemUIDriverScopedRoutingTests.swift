// scoped 経路(`/systemui/*`)の宛先が**名前空間ごと**正しいことの固定。
//
// 事故の形はどちらも沈黙する:
//   ① `/systemui/tap` の 404 を「旧ランナー」と読んで `/tap` へ撃ち直すと、**両方の
//      名前空間が 1 から採番される**ので番号がアプリ側の refFrames で引き当たり、
//      SpringBoard を叩いたつもりで無関係なアプリの要素をタップする
//   ② tapAppIcon は直前に `home()` を撃つので、ページ送りを `/drag` へ流すと
//      **背面アプリ**の座標解決で XCUITest が約45秒ハングしてランナーごと落ちる
// どちらも「200 が返る」「落ちるのは別の場所」なので、宛先そのものを固定する。

import XCTest
@testable import FTBridgeClient
import FTCore

/// 受けた「METHOD PATH」を順に記録し、パスごとに決めた status を返す最小 HTTP スタブ。
private final class RoutingStubServer {
    private var serverFD: Int32 = -1
    let port: UInt16
    private let lock = NSLock()
    private var _paths: [String] = []
    /// パス → 返す (status, body)。未登録は 200 `{"ok":true}`
    private let responses: [String: (status: Int, body: String)]

    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    func received(_ path: String) -> Bool { paths.contains(path) }

    init(responses: [String: (status: Int, body: String)] = [:]) throws {
        self.responses = responses
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
                // ヘッダと本文は別セグメントで来る。要求行が読めれば宛先は分かるので、
                // Content-Length ぶんを読み切るまで待つ(本文は使わない)
                var raw = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                var route = ""
                while true {
                    let n = read(c, &buffer, buffer.count)
                    if n <= 0 { break }
                    raw.append(contentsOf: buffer[0..<n])
                    guard let text = String(data: raw, encoding: .utf8),
                          let headerEnd = text.range(of: "\r\n\r\n") else { continue }
                    let header = String(text[text.startIndex..<headerEnd.lowerBound])
                    let head = header.split(separator: " ")
                    if head.count >= 2 {
                        // クエリ(`?max=`)は宛先の一部ではないので落とす
                        route = "\(head[0]) \(head[1].split(separator: "?")[0])"
                    }
                    let length = header.components(separatedBy: "\r\n")
                        .first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    if String(text[headerEnd.upperBound...]).utf8.count >= length { break }
                }
                if !route.isEmpty, let self {
                    self.lock.lock(); self._paths.append(route); self.lock.unlock()
                }
                let picked = self?.responses[route] ?? (200, #"{"ok":true}"#)
                let response = "HTTP/1.1 \(picked.status) X\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(picked.body.utf8.count)\r\nConnection: close\r\n\r\n\(picked.body)"
                _ = response.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }
    }

    func stop() { if serverFD >= 0 { close(serverFD); serverFD = -1 } }
    deinit { stop() }

    enum Failure: Error { case socket(Int32), bind(Int32), listen(Int32) }
}

final class SystemUIDriverScopedRoutingTests: XCTestCase {

    /// ref 1 を1つだけ持つ SpringBoard の木(scoped snapshot の応答)
    private static var scopedSnapshotBody: String {
        let element = ElementInfo(ref: 1, type: "button", identifier: "icon", label: "App",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 10, y: 20, width: 40, height: 60), depth: 1)
        let response = SnapshotResponse(sessionBundleID: "com.apple.springboard",
                                        screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                        elements: [element], truncatedCount: 0)
        return String(data: try! JSONEncoder().encode(response), encoding: .utf8)!
    }

    private func scopedDriver(extra: [String: (status: Int, body: String)] = [:])
        throws -> (RoutingStubServer, SystemUIDriver) {
        var responses = ["GET /systemui/snapshot": (200, Self.scopedSnapshotBody)]
        for (k, v) in extra { responses[k] = v }
        let stub = try RoutingStubServer(responses: responses)
        return (stub, SystemUIDriver(port: stub.port, host: BridgeEndpoint.loopbackHost,
                              sharesPrimarySession: true))
    }

    /// **知らない ref の 404 を「旧ランナー」と読み替えない**。読み替えると同じ番号が
    /// アプリ側の refFrames で引き当たり、別の要素を黙って叩く
    func testUnknownScopedRefDoesNotFallBackToTheAppRefTable() async throws {
        let (stub, driver) = try scopedDriver(
            extra: ["POST /systemui/tap": (404, #"{"error":"unknown system-UI reference number [1]"}"#)])
        defer { stub.stop() }
        _ = try await driver.snapshot()

        do {
            try await driver.tap(ref: 1)
            XCTFail("知らない ref の 404 が握り潰された")
        } catch {
            // 期待どおり
        }
        XCTAssertTrue(stub.received("POST /systemui/tap"))
        XCTAssertFalse(stub.received("POST /tap"),
                       "アプリの ref 表へ撃ち直している: 同じ番号が別の要素に当たる")
    }

    /// scoped ではジェスチャも SpringBoard 基準の口へ回す(tapAppIcon は `home()` の直後に
    /// 呼ぶので、セッションのアプリを原点にする `/drag`・`/swipe` はハングか 503 になる)
    func testScopedGesturesGoToTheSpringboardAnchoredRoutes() async throws {
        let (stub, driver) = try scopedDriver()
        defer { stub.stop() }
        _ = try await driver.snapshot()

        try await driver.drag(fromX: 300, fromY: 400, toX: 60, toY: 400,
                              pressSeconds: 0.05, durationSeconds: 0.2)
        try await driver.swipe(.left)

        XCTAssertTrue(stub.received("POST /systemui/drag"))
        XCTAssertTrue(stub.received("POST /systemui/swipe"))
        XCTAssertFalse(stub.received("POST /drag"), "背面アプリを原点にしている")
        XCTAssertFalse(stub.received("POST /swipe"), "背面アプリを原点にしている")
    }

    /// 長押しは口が無いので**座標へ落とす**(番号のまま `/press` へ流すとアプリ側で引き当たる)
    func testScopedPressResolvesTheRefToCoordinates() async throws {
        let (stub, driver) = try scopedDriver()
        defer { stub.stop() }
        _ = try await driver.snapshot()

        try await driver.press(ref: 1, duration: 0.5)
        XCTAssertTrue(stub.received("POST /press"))

        // 撮った木に無い番号は、アプリの表へ流さず落ちる
        do {
            try await driver.press(ref: 99, duration: 0.5)
            XCTFail("撮っていない ref が素通しされた")
        } catch {
            // 期待どおり
        }
    }

    /// 要素そのものを引くコマンド(ランナーが読み返す)は座標へ落とせないので断る。
    /// **断らずに素通しすると、アプリ側の同じ番号の入力欄へ文字が入る**
    func testScopedTypeAndClearInputAreRefusedInsteadOfHittingTheApp() async throws {
        let (stub, driver) = try scopedDriver()
        defer { stub.stop() }
        _ = try await driver.snapshot()

        do {
            try await driver.type(ref: 1, text: "hello")
            XCTFail("type が素通しされた")
        } catch { }
        do {
            try await driver.clearInput(ref: 1)
            XCTFail("clearInput が素通しされた")
        } catch { }

        XCTAssertFalse(stub.received("POST /type"))
        XCTAssertFalse(stub.received("POST /clear"))
    }

    /// **hybrid(ブリッジを共有していない)は従来どおり**: セッションを springboard へ移し、
    /// ref もジェスチャもアプリ側のルートで撃つ。scoped の判定を広げていないことの対照
    func testHybridKeepsTheLegacySessionPath() async throws {
        let stub = try RoutingStubServer()
        defer { stub.stop() }
        let driver = SystemUIDriver(port: stub.port, host: BridgeEndpoint.loopbackHost,
                                    sharesPrimarySession: false)

        _ = try? await driver.snapshot()
        try await driver.tap(ref: 1)
        try await driver.swipe(.left)

        XCTAssertTrue(stub.received("POST /session"), "旧経路は springboard へ session を張る")
        XCTAssertTrue(stub.received("POST /tap"))
        XCTAssertTrue(stub.received("POST /swipe"))
        XCTAssertFalse(stub.received("GET /systemui/snapshot"))
        XCTAssertFalse(stub.received("POST /systemui/tap"))
    }
}
