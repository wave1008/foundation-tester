// InAppDriver.openURL の分岐固定: 対象 bundleID の解決と、ブリッジ死活による
// 「注入起動してから配送」/「そのまま warm 配送」の切り分け。
//
// `simctl openurl` は環境変数を渡せないため、アプリが死んでいる状態で撃つと dylib 未注入のまま
// 起動しブリッジごと死ぬ(コメント参照: Sources/FTBridgeClient/InAppDriver.swift)。
// このテストは実機/シミュレータを使わず、**エラーの種類**でどちらの経路を通ったかを見分ける:
// 死活 probe が失敗すれば relaunch(InAppLauncher.relaunch)を経由し、dylib 不在(repoRoot が
// テスト用の tmp ディレクトリで InAppBridge/build.sh を持たない)で必ず失敗する。
// probe が生きていれば relaunch を経由せず、BridgeClient.openURL の simctl 呼び出しで失敗する
// (存在しない UDID を渡すため)。

import XCTest
@testable import FTBridgeClient
import FTCore

/// GET /status に固定の JSON を返す最小 HTTP スタブ(InAppDriverTerminateTests と同型。
/// private スコープのため相乗りできず複製している)。
private final class OpenURLStatusStubServer {
    private var serverFD: Int32 = -1
    let port: UInt16

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

        let body = """
        {"ready":true,"device":"no-such-simulator","osVersion":"iOS 27.0","engine":"inapp"}
        """
        Thread.detachNewThread { [fd] in
            while true {
                var ca = sockaddr()
                var cl = socklen_t(MemoryLayout<sockaddr>.size)
                let c = accept(fd, &ca, &cl)
                if c < 0 { break }  // serverFD の close で脱出
                var buffer = [UInt8](repeating: 0, count: 1024)
                _ = read(c, &buffer, buffer.count)
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

final class InAppDriverOpenURLTests: XCTestCase {

    /// bundleID 引数なし・launch も未実施なら、死活 probe より先に明確なエラーで止まる
    /// (無応答だったときに何へ注入起動すればよいか分からないため)
    func testOpenURLWithoutBundleIDOrPriorLaunchThrows() async {
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                 udid: "no-such-udid", port: 1)  // ポートは使われない(guard で先に止まる)
        do {
            try await driver.openURL("fte2e://screen/detail", bundleID: nil)
            XCTFail("bundleID を解決できないのに配送してしまった")
        } catch let DriverError.badResponse(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("openURL needs a bundleID"), body)
        } catch {
            XCTFail("DriverError.badResponse ではない: \(error)")
        }
    }

    /// ブリッジが無応答(何も listen していないポート)なら launch() 経由の注入起動を試みること。
    /// repoRoot がテスト用 tmp ディレクトリ(InAppBridge/build.sh を持たない)なので
    /// dylibMissing で失敗する = relaunch を経由したことの証拠
    func testOpenURLRelaunchesWhenBridgeIsUnreachable() async {
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                 udid: "no-such-udid", port: 1)
        do {
            try await driver.openURL("fte2e://screen/detail", bundleID: "com.example.target")
            XCTFail("dylib が無いのに配送してしまった")
        } catch let error as InAppLauncherError {
            guard case .dylibMissing = error else {
                return XCTFail("dylibMissing 以外で失敗した(relaunch を経由していない?): \(error)")
            }
        } catch {
            XCTFail("InAppLauncherError.dylibMissing ではない(relaunch を経由していない?): \(error)")
        }
    }

    /// ブリッジが生きていれば(/status に応答)relaunch せず、BridgeClient.openURL(simctl 経路)へ
    /// 直行すること。存在しない UDID を渡した simctl openurl の失敗で経路を確かめる
    /// (relaunch を経由していれば dylibMissing になるはずで、そちらは出ないこと)
    func testOpenURLDoesNotRelaunchWhenBridgeIsAlive() async throws {
        let stub = try OpenURLStatusStubServer()
        defer { stub.stop() }
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                 udid: "no-such-udid", port: stub.port)
        do {
            try await driver.openURL("fte2e://screen/detail", bundleID: "com.example.target")
            XCTFail("存在しない UDID への simctl openurl が成功してしまった")
        } catch let DriverError.badResponse(_, body) {
            XCTAssertTrue(body.contains("simctl openurl failed"),
                          "simctl 経路の失敗ではない(relaunch を経由した?): \(body)")
        } catch {
            XCTFail("DriverError.badResponse ではない(relaunch を経由した場合 dylibMissing になる): \(error)")
        }
    }
}
