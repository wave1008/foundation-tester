// D3: `ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch` の「待つか即座に断るか」の
// 判断だけを切り出した純粋関数(`LocalDeviceLeaseWaitPolicy`)。I/O 無しで固定できる部分だけを
// ここで縛り、実際の待機ループ(シェル・sleep)は手動確認に任せる。

import FTRemote
import XCTest
@testable import fleetest

final class LocalDeviceLeaseWaitPolicyTests: XCTestCase {

    /// `--wait-lock` 無し = 経過に関わらず即座に断る(待機列に並ばない)
    func testGivesUpImmediatelyWithoutWaitLock() {
        XCTAssertEqual(LocalDeviceLeaseWaitPolicy.decide(elapsedSeconds: 0, waitLock: nil), .giveUp)
        XCTAssertEqual(LocalDeviceLeaseWaitPolicy.decide(elapsedSeconds: 100, waitLock: nil), .giveUp)
    }

    /// `--wait-lock` あり = 上限に達するまで retry する。**新しい刻みの定数を作らず**
    /// dispatch.lock の待機(`WaitLockPolling.decide`)と同じ式に委ねていることを固定する
    /// (別の式を持つと、この待機だけ刻みがずれて拡張のログと数字が食い違う)
    func testRetriesUntilTheSameLimitDispatchLockWaitingUses() {
        XCTAssertEqual(LocalDeviceLeaseWaitPolicy.decide(elapsedSeconds: 0, waitLock: 300), .retry)
        XCTAssertEqual(LocalDeviceLeaseWaitPolicy.decide(elapsedSeconds: 290, waitLock: 300), .retry)
        XCTAssertEqual(LocalDeviceLeaseWaitPolicy.decide(elapsedSeconds: 300, waitLock: 300), .giveUp)
        for elapsed in [0, 150, 300, 301] {
            XCTAssertEqual(WaitLockPolling.decide(elapsedSeconds: elapsed, limitSeconds: 300),
                           LocalDeviceLeaseWaitPolicy.decide(elapsedSeconds: elapsed, waitLock: 300),
                           "WaitLockPolling.decide と別の式を持ってしまっている(elapsed=\(elapsed))")
        }
    }
}
