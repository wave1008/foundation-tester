// 「ポートで応答しているのに、このリポジトリの状態ファイルに記録が無い」ブリッジの扱い。
//
// 実害(2026-07-30): 別クローンが起動した protocolVersion 4 のランナーがポート 8127 と
// シミュレータを 7 時間 22 分占有していた。`ftester bridge down --port 8127` は
// 「ブリッジは起動していません(.ftester/bridge.pid なし)」と応え、**応答している事実と
// 食い違う**メッセージのせいで切り分けに時間を要した。文言は診断そのものなので固定する。

import XCTest
import FTBridgeClient

final class ForeignBridgeErrorTests: XCTestCase {

    func testNotOwnedMessageStatesItIsAliveAndNotOurs() {
        let error = LauncherError.notOwnedByThisRepo(
            port: 8127, device: "iPhone 17 Pro", protocolVersion: 4)
        let message = try! XCTUnwrap(error.errorDescription)

        XCTAssertTrue(message.contains("8127"), "ポートを出すこと: \(message)")
        XCTAssertTrue(message.contains("iPhone 17 Pro"), "デバイスを出すこと: \(message)")
        XCTAssertTrue(message.contains("4"), "版を出すこと: \(message)")
        // 「起動していません」と読める文言を混ぜない(事実と食い違うのが元の問題)
        XCTAssertFalse(message.contains("is not running"),
                       "応答しているのに『起動していない』と言わない: \(message)")
        XCTAssertTrue(message.contains("lsof"), "手詰まりにしない=次の手を出すこと: \(message)")
    }

    func testNotOwnedMessageToleratesUnknownDeviceAndVersion() {
        // /status が壊れていて device/version が取れなくても文言を組み立てられる
        let error = LauncherError.notOwnedByThisRepo(port: 8130, device: nil, protocolVersion: nil)
        let message = try! XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("8130"))
        XCTAssertTrue(message.contains("unknown"), "不明であることを明示する: \(message)")
    }

    func testNotRunningKeepsItsOwnMessage() {
        // 本当に誰も応答していないケースは従来どおり(退行防止)
        let message = try! XCTUnwrap(LauncherError.notRunning.errorDescription)
        XCTAssertTrue(message.contains("is not running"))
    }

    /// stop() の配線そのもの: **応答があれば notRunning ではなく notOwnedByThisRepo を投げる**。
    /// 文言テストだけだと「プローブを呼ばない」退行を見逃す(実際に変異テストで素通りした)。
    func testStopReportsForeignBridgeWhenPortAnswers() throws {
        let port: UInt16 = 8191
        // **固定ポートなので、実物のブリッジが先に居ることがある**(ブリッジのポート帯と重なる。
        // 2026-08-11 に手動プローブのブリッジが 8191 に居て、このテストがその実物の
        // device/version を読んで落ちた)。自前サーバは bind に失敗しても probe は成功するので、
        // **先に誰も居ないことを確かめてから**始める(居るなら skip = 誤った失敗を出さない)
        try XCTSkipUnless(BridgeLauncher.probeForeignBridge(port: port, timeout: 0.3) == nil,
                          "port \(port) に別のブリッジが応答しています(このテストは固定ポートを使う)")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-c", """
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"ready": True, "device": "テスト機", "protocolVersion": 1}).encode()
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", \(port)), H).serve_forever()
"""]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }

        // 起動待ち(接続できるまで最大 3 秒)
        var ready = false
        for _ in 0..<30 where !ready {
            if BridgeLauncher.probeForeignBridge(port: port, timeout: 0.3) != nil { ready = true }
            else { Thread.sleep(forTimeInterval: 0.1) }
        }
        try XCTSkipUnless(ready, "テスト用 HTTP サーバを起動できませんでした")

        // 状態ファイルが1つも無い一時ディレクトリを repoRoot にする
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTBridgeClientTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temp.appendingPathComponent(".ftester"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        XCTAssertThrowsError(try BridgeLauncher(repoRoot: temp, port: port).stop()) { error in
            guard case LauncherError.notOwnedByThisRepo(let p, let device, let version) = error else {
                return XCTFail("notOwnedByThisRepo を投げるはず: \(error)")
            }
            XCTAssertEqual(p, port)
            XCTAssertEqual(device, "テスト機")
            XCTAssertEqual(version, 1)
        }
    }

    func testProbeReturnsNilForAPortWithNoListener() throws {
        // 応答が無ければ nil = notRunning へ倒れる。短いタイムアウトで返ること。
        // **ポート番号を決め打ちしない**(2026-08-10): 8199 固定だったため、開発中に立てた
        // ブリッジが同じ番号を使っていると落ちた。ポートはホスト全体の共有資源で、
        // テストの外(別セッション・手で立てたブリッジ)とも衝突する。OS に空きを1つ選ばせ、
        // 閉じてから、その番号を「誰も居ない港」として使う
        let port = try Self.portWithNoListener()
        let start = Date()
        XCTAssertNil(BridgeLauncher.probeForeignBridge(port: port, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0, "プローブが長引かないこと")
    }

    /// OS に空きポートを1つ選ばせて即座に閉じる。返した瞬間に誰かが掴む可能性はゼロではないが、
    /// 固定番号(= 実際に使われている番号)よりはるかに安全
    private static func portWithNoListener() throws -> UInt16 {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw XCTSkip("socket を開けない") }
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0            // 0 = OS が空きを選ぶ
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var bound = addr
        let ok = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else { throw XCTSkip("bind できない") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length) == 0
            }
        }
        guard got else { throw XCTSkip("getsockname できない") }
        return UInt16(bigEndian: actual.sin_port)
    }
}
