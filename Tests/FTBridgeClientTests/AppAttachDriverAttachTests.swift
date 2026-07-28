// AppAttachDriver が「ref 無し操作の前にセッションを自分の bundleID へ揃える」ことの固定。
// これを外すと、使い回された XCUITest ブリッジのセッションが**前のプロジェクトのアプリ**を
// 指したままジェスチャを撃ち、無言で別アプリを操作する(実測: E2E-iOS の次に回った
// E2E-Flutter の scrollTo が 12 回空振り。ランナーが落ちる経路もある。design.md 参照)。

import XCTest
@testable import FTBridgeClient
import FTCore

/// 受けたリクエストのパスを順に記録し、すべて 200 `{}` を返す最小 HTTP スタブ。
private final class RecordingStubServer {
    private var serverFD: Int32 = -1
    let port: UInt16
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }

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
                var buffer = [UInt8](repeating: 0, count: 4096)
                let n = read(c, &buffer, buffer.count)
                if n > 0, let request = String(bytes: buffer[0..<n], encoding: .utf8) {
                    let head = request.split(separator: " ")
                    if head.count >= 2 {
                        self?.lock.lock()
                        self?._paths.append("\(head[0]) \(head[1])")
                        self?.lock.unlock()
                    }
                }
                let body = #"{"ok":true}"#  // OKResponse(BridgeDTO)と同じ形
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

final class AppAttachDriverAttachTests: XCTestCase {

    /// 最初の swipe の前に /session(activate)を打つこと。snapshot を経ないシナリオ
    /// (scrollTo が最初の操作)で、使い回しセッションが別アプリを指したまま撃たれるのを防ぐ
    func testFirstSwipeAttachesSessionFirst() async throws {
        let stub = try RecordingStubServer()
        defer { stub.stop() }
        let driver = AppAttachDriver(port: stub.port, bundleID: "com.example.target")

        try await driver.swipe(.up)

        XCTAssertEqual(stub.paths, ["POST /session", "POST /swipe"],
                       "swipe の前に attach すること: \(stub.paths)")
    }

    /// attach は 1 インスタンスにつき 1 回だけ(activate は refFrames をクリアするので、
    /// 毎回打つと直前 snapshot の ref が無効になる)
    func testAttachHappensOnlyOncePerInstance() async throws {
        let stub = try RecordingStubServer()
        defer { stub.stop() }
        let driver = AppAttachDriver(port: stub.port, bundleID: "com.example.target")

        try await driver.swipe(.up)
        try await driver.swipe(.down)
        try await driver.drag(fromX: 1, fromY: 2, toX: 3, toY: 4,
                              pressSeconds: 0.05, durationSeconds: 0.05)

        XCTAssertEqual(stub.paths.filter { $0 == "POST /session" }.count, 1,
                       "attach は1回だけであること: \(stub.paths)")
    }

    /// snapshot() の activate でも attached が立つこと(直後の swipe で二重 attach しない)
    func testSnapshotCountsAsAttach() async throws {
        let stub = try RecordingStubServer()
        defer { stub.stop() }
        let driver = AppAttachDriver(port: stub.port, bundleID: "com.example.target")

        _ = try? await driver.snapshot()
        try await driver.swipe(.up)

        XCTAssertEqual(stub.paths.filter { $0 == "POST /session" }.count, 1,
                       "snapshot の activate 後に再 attach しないこと: \(stub.paths)")
    }
}
