// InAppDriver.terminate の対象アプリ解決。**失敗が「黙って何もしない」形で出る**箇所なので、
// launchApp を経ていないときに /status を引きに行くことをここで固定する。
// simctl は実際に走るが、存在しない UDID なので即エラー(InAppLauncher が握り潰す)。

import XCTest
@testable import FTBridgeClient
import FTCore

/// GET /status に固定の JSON を返し、受けたパスを記録する最小 HTTP スタブ。
private final class StatusStubServer {
    private var serverFD: Int32 = -1
    let port: UInt16
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }

    init(sessionBundleID: String) throws {
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

        let body = """
        {"ready":true,"device":"stub","osVersion":"iOS 27.0","engine":"inapp",\
        "sessionBundleID":"\(sessionBundleID)"}
        """
        Thread.detachNewThread { [weak self, fd] in
            while true {
                var ca = sockaddr()
                var cl = socklen_t(MemoryLayout<sockaddr>.size)
                let c = accept(fd, &ca, &cl)
                if c < 0 { break }  // serverFD の close で脱出
                var buffer = [UInt8](repeating: 0, count: 1024)
                let n = read(c, &buffer, buffer.count)
                if n > 0, let request = String(bytes: buffer[0..<n], encoding: .utf8),
                   let path = request.split(separator: " ").dropFirst().first {
                    self?.lock.lock()
                    self?._paths.append(String(path))
                    self?.lock.unlock()
                }
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

final class InAppDriverTerminateTests: XCTestCase {

    /// launchApp を経ていない(lastBundleID が nil)なら /status の sessionBundleID を対象にすること。
    /// 以前は黙って return し、terminateApp が**何もしないまま成功**していた
    func testTerminateWithoutLaunchResolvesTargetFromStatus() async throws {
        let stub = try StatusStubServer(sessionBundleID: "com.example.injected")
        defer { stub.stop() }
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                 udid: "no-such-udid", port: stub.port)

        try await driver.terminate()

        XCTAssertTrue(stub.paths.contains("/status"),
                      "launch 前の terminate は注入先を /status から引くこと: \(stub.paths)")
    }

    /// launch 済みなら /status を引かずに直近の bundleID を使うこと(往復を増やさない)
    func testTerminateAfterLaunchDoesNotQueryStatus() async throws {
        let stub = try StatusStubServer(sessionBundleID: "com.example.injected")
        defer { stub.stop() }
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                 udid: "no-such-udid", port: stub.port)
        // launch は simctl 注入に失敗するが lastBundleID は先に立つ(失敗は無視してよい)
        _ = try? await driver.launch(bundleID: "com.example.target")

        try await driver.terminate()

        XCTAssertFalse(stub.paths.contains("/status"),
                       "launch 済みなら /status を引かないこと: \(stub.paths)")
    }
}
