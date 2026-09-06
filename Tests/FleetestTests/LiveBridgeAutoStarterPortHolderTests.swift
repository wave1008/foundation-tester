import XCTest

/// LiveBridgeAutoStarter.launchBridge は固定ポートで直接 startDetached していた。
/// 背面へ回った in-app ブリッジ(TCP は受け付けるが HTTP に答えない・.pid も持たない)が
/// そのポートを握っていると bindFailed(48) で気づく無情報な失敗になる
/// (BridgeProvisioner.executeBridge は起動前に PortHolder で LISTEN の実体を確かめている)。
/// また、実機は establish で到達手段(LAN 宛先解決/iproxy)を確立してから待たないと、
/// ループバックを待ち続けて必ず 180 秒後に failed になる欠陥が指摘された。
/// ソース走査でこの2つの配線を固定する。
final class LiveBridgeAutoStarterPortHolderTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testLaunchBridgeChecksPortHolderBeforeStarting() throws {
        let code = try source("Sources/fleetest/LiveBridgeAutoStarter.swift")
        guard let holderRange = code.range(of: "PortHolder.stopIfOwnedBridge") else {
            return XCTFail("PortHolder.stopIfOwnedBridge を呼んでいない — "
                + "背面の in-app ブリッジが握るポートを空きと誤認し bindFailed(48) で落ちる")
        }
        guard let startRange = code.range(of: "startDetached()") else {
            return XCTFail("startDetached() が見当たらない")
        }
        XCTAssertTrue(holderRange.upperBound < startRange.lowerBound,
                      "PortHolder の確認は startDetached より前に行うこと")
    }

    func testLaunchBridgeEstablishesPhysicalTransportBeforeWaiting() throws {
        let code = try source("Sources/fleetest/LiveBridgeAutoStarter.swift")
        guard let establishRange = code.range(of: "IOSDeviceTransport.establish") else {
            return XCTFail("IOSDeviceTransport.establish を呼んでいない — "
                + "実機のブリッジ復帰がループバックを待ち続けて必ずタイムアウトする")
        }
        guard let waitRange = code.range(of: "waitUntilReady(host: host") else {
            return XCTFail("establish の結果(host)を waitUntilReady へ渡していない")
        }
        XCTAssertTrue(establishRange.upperBound < waitRange.lowerBound,
                      "establish は waitUntilReady より前に呼ぶこと")
    }
}
