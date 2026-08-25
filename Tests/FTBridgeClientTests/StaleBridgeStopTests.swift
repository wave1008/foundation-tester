// 再利用できない旧ブリッジを止める手段の決定(StaleBridgeStop)と、ポート占有者の名指し
// (PortHolder.describe / portInUse の文言)の固定。
//
// 2026-08-22/23 の受け手報告: 前の run の in-app ブリッジ(iosApp)が記録無しでポートに居座り、
// 供給が「the bridge is not running (no .ftester/bridge.pid)」で止めそこねたまま新規注入へ進んで
// 「did not respond in time」で never joined になった。残骸が原因だとメッセージからは分からなかった。

import XCTest
import Foundation
@testable import FTBridgeClient

final class StaleBridgeStopTests: XCTestCase {

    /// 記録の無い旧ブリッジは **.pid 経路へ流さない**(流すと「no bridge.pid」で止めそこねる)
    func testUntrackedStaleBridgeIsStoppedByItsPortHolder() {
        XCTAssertEqual(StaleBridgeStop.decide(hasInAppRecord: false, hasPidFile: false), .stopPortHolder)
    }

    func testRecordedInAppIsTerminatedByRecord() {
        XCTAssertEqual(StaleBridgeStop.decide(hasInAppRecord: true, hasPidFile: false),
                       .terminateRecordedInApp)
        // 両方ある(通常は起きない)なら in-app の記録を優先する —— simctl terminate は
        // プロセス kill より安全な後始末で、.pid は stale な可能性が高い
        XCTAssertEqual(StaleBridgeStop.decide(hasInAppRecord: true, hasPidFile: true),
                       .terminateRecordedInApp)
    }

    func testRunnerWithPidFileIsStoppedAsRunner() {
        XCTAssertEqual(StaleBridgeStop.decide(hasInAppRecord: false, hasPidFile: true), .stopRunner)
    }

    /// 衝突の失敗文言は**占有者を名指し**する(pid とコマンド)。これが無いと残骸が原因だと分からない
    func testPortInUseNamesTheHolder() {
        let error = BridgeProvisionerError.notReady(
            port: 8128,
            underlying: LauncherError.portInUse(port: 8128, holder: "pid 29427: /…/otherclone"))
        let text = error.localizedDescription
        XCTAssertTrue(text.contains("port 8128 is in use by another process"), text)
        XCTAssertTrue(text.contains("pid 29427"), text)
    }

    /// PortHolder.describe は LISTEN している実プロセスを pid 付きで言い当て、**止めない**。
    /// 実プロセス(nc -l)を立てて確かめる。ポートは衝突しにくい高番号をランダムに選ぶ
    func testDescribeNamesTheListeningProcessWithoutStoppingIt() throws {
        let port = UInt16(Int.random(in: 40000...50000))
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-l", "127.0.0.1", String(port)]
        try nc.run()
        defer { nc.terminate(); nc.waitUntilExit() }
        // LISTEN が立つまで待つ(最大 3 秒)
        let deadline = Date().addingTimeInterval(3)
        var description: String?
        while Date() < deadline {
            description = PortHolder.describe(port: port)
            if description != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let description else {
            return XCTFail("nc -l \(port) を LISTEN として言い当てられない")
        }
        XCTAssertTrue(description.contains("pid \(nc.processIdentifier)"), description)
        XCTAssertTrue(description.contains("nc"), description)
        XCTAssertTrue(nc.isRunning, "describe は占有者を止めてはいけない")
    }

    func testDescribeReturnsNilWhenNothingListens() {
        // 使われていないポートを選ぶ: bind して即閉じたポートは直後は空いている公算が高いが、
        // 厳密には保証できないので 2 つ試して 1 つでも nil なら良しとする(偽陽性を避ける側)
        let ports = [UInt16(Int.random(in: 50001...60000)), UInt16(Int.random(in: 50001...60000))]
        XCTAssertTrue(ports.contains { PortHolder.describe(port: $0) == nil })
    }
}
