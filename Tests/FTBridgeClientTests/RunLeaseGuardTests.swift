// run が同じ台へ二重に走らないよう、供給フェーズが lease を書く前に拒否する判定
// (RunLeaseGuard.conflicts)の契約。純粋関数なのでファイル I/O は holderPID クロージャで注入する。

import XCTest
@testable import FTBridgeClient

final class RunLeaseGuardTests: XCTestCase {
    func testNoConflictWhenNoHolder() {
        let conflicts = RunLeaseGuard.conflicts(
            devices: [(device: "iPhone 17-01", key: "UDID-1")],
            selfPID: 100,
            holderPID: { _ in nil })
        XCTAssertTrue(conflicts.isEmpty)
    }

    // 自分自身の pid が握っている lease(同一プロセスの供給フェーズが既に書いた分等)は
    // 衝突と見なさない —— これが無いと、自分の run がずっと自分自身を拒否し続ける
    func testSelfPIDIsNotAConflict() {
        let conflicts = RunLeaseGuard.conflicts(
            devices: [(device: "Pixel 9 -01", key: "emulator-5554")],
            selfPID: 100,
            holderPID: { _ in 100 })
        XCTAssertTrue(conflicts.isEmpty)
    }

    // 戻すと落ちる根拠: 生きた別プロセスの lease を無視して素通しするようになる(同じ台へ2つの run が無警告で当たる)
    func testOtherLivePIDIsAConflict() {
        let conflicts = RunLeaseGuard.conflicts(
            devices: [(device: "Pixel 9 -01", key: "emulator-5554")],
            selfPID: 100,
            holderPID: { _ in 42 })
        XCTAssertEqual(conflicts, [RunLeaseGuard.Conflict(
            device: "Pixel 9 -01", key: "emulator-5554", holderPID: 42)])
    }

    func testOnlyLeasedDevicesAreReported() {
        let conflicts = RunLeaseGuard.conflicts(
            devices: [(device: "free device", key: "k1"), (device: "busy device", key: "k2")],
            selfPID: 100,
            holderPID: { $0 == "k2" ? 42 : nil })
        XCTAssertEqual(conflicts.map(\.device), ["busy device"])
    }

    // 同じキーが複数のワーカー呼び出し元(Android/iOS の両供給フェーズをまとめて渡す等)から
    // 重複して渡っても、1件だけ報告する
    func testDeduplicatesByKey() {
        let conflicts = RunLeaseGuard.conflicts(
            devices: [(device: "a", key: "k1"), (device: "a", key: "k1")],
            selfPID: 100,
            holderPID: { _ in 42 })
        XCTAssertEqual(conflicts.count, 1)
    }

    // ユーザー決定「拒否して止める」: メッセージは台名と保持者 pid を名指しする
    func testMessageNamesDeviceAndHolderPID() {
        let message = RunLeaseGuard.message([
            RunLeaseGuard.Conflict(device: "Pixel 9 -01", key: "emulator-5554", holderPID: 4242)])
        XCTAssertTrue(message.contains("Pixel 9 -01"))
        XCTAssertTrue(message.contains("4242"))
    }
}
