// `devicectl device info lockState` の読み取り。**現物の JSON で固定する**
// (2026-08-27 に iPhone SE3 / Xcode 27 beta6 で実測した2形。devicectl 642.15)。
// 見落とし(unknown)は許すが、**解除済みを locked と誤る側には倒さない**

import Foundation
import XCTest
@testable import FTBridgeClient

final class IOSPhysicalDeviceLockTests: XCTestCase {

    private func json(passcodeRequired: Bool) -> Data {
        Data("""
        {"info":{"commandType":"devicectl.device.info.lockState","jsonVersion":5,
                 "outcome":"success","version":"642.15"},
         "result":{"deviceIdentifier":"9D3C226E-EE5B-501D-9575-6636BD89314B",
                   "passcodeRequired":\(passcodeRequired),"unlockedSinceBoot":true}}
        """.utf8)
    }

    func testLockedWhenPasscodeIsRequiredNow() {
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(json(passcodeRequired: true)), .locked)
    }

    func testUnlockedWhenNoPasscodeIsRequired() {
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(json(passcodeRequired: false)), .unlocked)
    }

    /// `unlockedSinceBoot`(起動以降に一度でも解除したか=データ保護)を掴んでいないこと。
    /// これは**画面ロックの現況ではない**ので、ロック中でも true のままになる
    func testIgnoresUnlockedSinceBoot() {
        let data = Data("""
        {"result":{"unlockedSinceBoot":true}}
        """.utf8)
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(data), .unknown,
                       "passcodeRequired が無い応答を解除済みと読んではいけない")
    }

    /// 形式が変わった・devicectl が失敗した場合は unknown(促さない)
    func testMalformedIsUnknown() {
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(Data("not json".utf8)), .unknown)
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(Data("{}".utf8)), .unknown)
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(
            Data(#"{"result":{"passcodeRequired":"true"}}"#.utf8)), .unknown,
                       "文字列の \"true\" を真と読まないこと")
    }
}

/// 解除待ちの周回。**端末抜き**で回す(probe を差し替える)
final class IOSPhysicalDeviceLockWaitTests: XCTestCase {

    private func wait(_ states: [IOSPhysicalDeviceLock.State],
                      timeout: TimeInterval = 5) async
        -> (state: IOSPhysicalDeviceLock.State, log: [String]) {
        var remaining = states
        var lines: [String] = []
        let state = await IOSPhysicalDeviceLock.waitForUnlock(
            udid: "u", deviceName: "iPhone x", timeout: timeout,
            log: { lines.append($0) }, pollInterval: 0.01,
            probe: { _ in remaining.isEmpty ? .locked : remaining.removeFirst() })
        return (state, lines)
    }

    func testReturnsImmediatelyWhenAlreadyUnlocked() async {
        let result = await wait([.unlocked])
        XCTAssertEqual(result.state, .unlocked)
        XCTAssertTrue(result.log.isEmpty, "解除済みなら促さない: \(result.log)")
    }

    func testPromptsOnceThenProceedsWhenUnlocked() async {
        let result = await wait([.locked, .locked, .unlocked])
        XCTAssertEqual(result.state, .unlocked)
        XCTAssertEqual(result.log.filter { $0.contains("is locked") }.count, 1,
                       "促しは1回だけ: \(result.log)")
        XCTAssertTrue(result.log.contains { $0.contains("unlocked") }, "\(result.log)")
    }

    /// **読めなくなっただけを「解除された」と読まない**(読むと、ロックされたままの端末へ
    /// 起動を撃って無情報な締切待ちに戻る)
    func testUnknownIsNotReportedAsUnlocked() async {
        let result = await wait([.locked, .unknown])
        XCTAssertEqual(result.state, .unknown)
        XCTAssertFalse(result.log.contains { $0.contains("unlocked") },
                       "unknown を解除済みと言ってはいけない: \(result.log)")
    }

    /// **中断されたら待ちを抜ける**。抜けないと刻みが 0 になり、締切まで devicectl を
    /// 数百回起動し続ける(Ctrl+C 後の実挙動)
    func testCancellationEndsTheWait() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let probes = Counter()
        let task = Task {
            await IOSPhysicalDeviceLock.waitForUnlock(
                udid: "u", deviceName: "iPhone x", timeout: 2, log: { _ in },
                pollInterval: 0.05, probe: { _ in probes.bump(); return .locked })
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(probes.count, 20,
                          "中断後も回り続けている(\(probes.count) 回 devicectl を叩いた)")
    }

    func testStaysLockedUntilTheDeadline() async {
        let result = await wait([.locked], timeout: 0.05)
        XCTAssertEqual(result.state, .locked)
    }
}
