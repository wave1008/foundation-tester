// XCUIBridgeResolver.start は「空きポート」の判定を .pid ファイルと稼働中(応答あり)ポートだけで
// 行っていた。背面へ回った in-app ブリッジ(TCP は受け付けるが HTTP に答えない・.pid も持たない)は
// どちらにも映らないため空きに見え、そのまま startDetached すると bindFailed(48) で giveUp する
// (BridgeProvisioner.executeBridge は起動前に PortHolder で LISTEN の実体を確かめており、
// resolver 側だけこの確認を欠いていた)。ソース走査で「起動前に PortHolder を呼んでいるか」を
// 固定する(実プロセスを LISTEN させて検証するのは重い割に得るものが薄いため、配線の有無を見る)。

import XCTest

final class XCUIBridgeResolverPortHolderTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// startDetached の前に PortHolder.stopIfOwnedBridge を呼んでいること(BridgeProvisioner.
    /// executeBridge と同じ判定。二つ目の実装を書かず PortHolder/StaleBridgeStop を再利用する)
    func testResolverChecksPortHolderBeforeStarting() throws {
        let code = try source("Sources/FTBridgeClient/XCUIBridgeResolver.swift")
        guard let holderRange = code.range(of: "PortHolder.stopIfOwnedBridge") else {
            return XCTFail("PortHolder.stopIfOwnedBridge を呼んでいない — "
                + "背面の in-app ブリッジが握るポートを空きと誤認し bindFailed(48) で落ちる")
        }
        guard let startRange = code.range(of: "startDetached()") else {
            return XCTFail("startDetached() が見当たらない")
        }
        XCTAssertTrue(holderRange.upperBound < startRange.lowerBound,
                      "PortHolder の確認は startDetached より前に行うこと(起動前に LISTEN 実体を確かめる)")
    }

    /// 実機は establish で到達手段(LAN 宛先解決 / iproxy トンネル)を確立してから waitUntilReady を
    /// 呼ぶこと。これが無いとループバックを待ち続け、実機では必ず 180 秒後に failed になる
    func testResolverEstablishesPhysicalTransportBeforeWaiting() throws {
        let code = try source("Sources/FTBridgeClient/XCUIBridgeResolver.swift")
        guard let establishRange = code.range(of: "IOSDeviceTransport.establish") else {
            return XCTFail("IOSDeviceTransport.establish を呼んでいない — "
                + "実機のブリッジ起動がループバックを待ち続けて必ずタイムアウトする")
        }
        guard let waitRange = code.range(of: "waitUntilReady(host: host") else {
            return XCTFail("establish の結果(host)を waitUntilReady へ渡していない")
        }
        XCTAssertTrue(establishRange.upperBound < waitRange.lowerBound,
                      "establish は waitUntilReady より前に呼ぶこと")
    }
}
