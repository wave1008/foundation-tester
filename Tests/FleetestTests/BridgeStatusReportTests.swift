// `fleetest bridge status`(iOS)の表示。
//
// なぜ要るか(2026-09-04 の実害): 旧実装は既定ポート1本へ問い合わせて落ちるだけで、
// **8本動いている状態で**「nothing listening / アプリが落ちたのだろう」と報告していた
// (既定の 8123 が空いていただけ)。読み手は「全滅した」と誤解する。Android 側は元から
// 接続中の全 serial を列挙しており、非対称でもあった。

import XCTest
@testable import fleetest
import FTBridgeClient

final class BridgeStatusReportTests: XCTestCase {

    private func found(_ port: UInt16, _ device: String, _ engine: String,
                       udid: String? = nil) -> BridgeDiscovery.Found {
        BridgeDiscovery.Found(port: port, device: device, engine: engine, udid: udid)
    }

    /// **動いているものを全部出す**。1本しか出さない実装へ戻ると落ちる
    func testEveryRunningBridgeIsListed() {
        let text = BridgeStatusReport.render([
            found(8130, "iPhone 17 Pro-06", "xcuitest"),
            found(8124, "iPhone 17 Pro-01", "inapp", udid: "UD-1"),
        ], silent: [], requested: 8123)
        XCTAssertTrue(text.contains("port 8124"), text)
        XCTAssertTrue(text.contains("port 8130"), text)
        XCTAssertTrue(text.contains("inapp"), "エンジンは取り違え防止に必ず出す")
        XCTAssertTrue(text.contains("UD-1"), "udid があれば出す")
    }

    /// ポート昇順(走査は並列なので到着順に出すと毎回並びが変わる)
    func testRowsAreSortedByPort() {
        let text = BridgeStatusReport.render([
            found(8132, "d8", "xcuitest"), found(8124, "d1", "xcuitest"),
        ], silent: [], requested: 8123)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("8124"), text)
        XCTAssertTrue(lines[1].contains("8132"), text)
    }

    /// `--port` を渡した人が自分の1本を見失わないよう印を付ける
    func testTheRequestedPortIsMarked() {
        let text = BridgeStatusReport.render([
            found(8124, "d1", "xcuitest"), found(8125, "d2", "xcuitest"),
        ], silent: [], requested: 8125)
        let marked = text.split(separator: "\n").first { $0.contains("8125") }
        XCTAssertTrue(marked?.hasPrefix("→") == true, text)
        let other = text.split(separator: "\n").first { $0.contains("8124") }
        XCTAssertFalse(other?.hasPrefix("→") == true, text)
    }

    /// **1本も無いときは「何も無い」と言う**(旧実装のように「アプリが落ちた」と言わない)。
    /// 走査した範囲まで出す = 読み手が「その範囲の外に居るのでは」を自分で疑える
    func testTheEmptyCaseSaysSoAndNamesTheScannedRange() {
        let text = BridgeStatusReport.render([], silent: [], requested: 8123)
        XCTAssertTrue(text.contains("no bridge is running"), text)
        XCTAssertTrue(text.contains("fleetest bridge up"), text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("crash"),
                       "アプリが落ちたと言わない: \(text)")
    }

    /// **待受しているのに答えなかったポートも行にする**(忙しい1本が一覧から消えていた)
    func testSilentListeningPortsAreListedWithTheirUdid() {
        let text = BridgeStatusReport.render(
            [found(8124, "d1", "xcuitest")],
            silent: [BridgeDiscovery.Silent(port: 8128, udid: "UD-9"), BridgeDiscovery.Silent(port: 8150)],
            requested: 8123)
        XCTAssertTrue(text.contains("port 8128: listening, but did not answer /status within 2s (busy or stuck) udid UD-9"), text)
        XCTAssertTrue(text.contains("port 8150: listening, but did not answer"), text)
        let ports = text.split(separator: "\n").map { $0.drop(while: { !$0.isNumber }).prefix(4) }
        XCTAssertEqual(ports.map(String.init), ["8124", "8128", "8150"], "答えた行と混ぜてポート昇順: \(text)")
    }

    /// **全部が忙しいときに「無い」と言い切らない**。「無い」は答えたものも待受だけのものも無いときだけ
    func testAllBusyIsNotReportedAsNoBridge() {
        let text = BridgeStatusReport.render([], silent: [BridgeDiscovery.Silent(port: 8128)], requested: 8123)
        XCTAssertFalse(text.contains("no bridge is running"), text)
        XCTAssertTrue(text.contains("port 8128"), text)
    }
}
