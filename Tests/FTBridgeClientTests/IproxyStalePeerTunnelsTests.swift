// M4: 実機のブリッジが別ポートで建て直されるとき、同じ UDID を向いた古い iproxy が
// 台帳(.fleetest/iproxy-<port>.pid)に残ったまま止められていなかった。実測(2026-09-17):
// SE3(1台)向けの iproxy が3本(現役1・前日以降の残骸2)全部 PPID=1 で生き残り、
// .fleetest/iproxy-8125.pid / iproxy-8133.pid も生きた pid のまま残っていた。
// iOS 実機は全ポートで bundle id が共通なので、1台に同居できる iproxy は1本だけ ——
// 余った古いトンネルはどれにも使われない。
//
// ここでは「台帳の一覧と各 pid の向き先から止める対象を決める」純粋関数(stalePeerPorts)だけを
// 検証する(I/O 側の stopStalePeerTunnels は既存の IproxyPidLedgerTests と同じ理由で実プロセスの
// コマンドラインを "iproxy" に偽装できないため対象外)。

import XCTest
@testable import FTBridgeClient

final class IproxyStalePeerTunnelsTests: XCTestCase {

    private let sameUDIDCommand = "/opt/homebrew/bin/iproxy 8125 8100 -u 00008110-000260242EEB801E"
    private let otherUDIDCommand = "/opt/homebrew/bin/iproxy 8140 8100 -u 00008110-DIFFERENT-DEVICE"

    func testSelectsOtherPortsPointingAtTheSameUDID() {
        let stale = IOSDeviceTransport.stalePeerPorts(
            entries: [(port: 8125, command: sameUDIDCommand), (port: 8133, command: sameUDIDCommand)],
            hostPort: 8124, deviceUDID: "00008110-000260242EEB801E")
        XCTAssertEqual(Set(stale), [8125, 8133])
    }

    func testExcludesTheHostPortItself() {
        let stale = IOSDeviceTransport.stalePeerPorts(
            entries: [(port: 8124, command: sameUDIDCommand)],
            hostPort: 8124, deviceUDID: "00008110-000260242EEB801E")
        XCTAssertEqual(stale, [], "今張った/再利用したトンネル自身は対象外")
    }

    func testExcludesTunnelsForADifferentUDID() {
        let stale = IOSDeviceTransport.stalePeerPorts(
            entries: [(port: 8140, command: otherUDIDCommand)],
            hostPort: 8124, deviceUDID: "00008110-000260242EEB801E")
        XCTAssertEqual(stale, [], "別デバイス向けのトンネルはどの台にも要らないと分かっても触らない")
    }

    func testEmptyLedgerYieldsNothingToStop() {
        XCTAssertEqual(IOSDeviceTransport.stalePeerPorts(
            entries: [], hostPort: 8124, deviceUDID: "00008110-000260242EEB801E"), [])
    }
}
