import XCTest

@testable import fleetest

/// `api live serve` のブリッジ自動復帰が**実機を実機として建て直す**ことを固定する。
///
/// 実害 2026-08-30: `LiveBridgeAutoStarter` が `BridgeLauncher` を `physical:` 無しで作っており、
/// 既定の `false` = シミュレータ扱いで起動していた。DerivedData も `-destination` も
/// シミュレータ用のまま実機へ向かうので、実機のライブ表示中にブリッジが落ちると復帰に必ず失敗する。
///
/// **呼び忘れ自体は `BridgeLauncher.init` から既定値を外したのでコンパイルで止まる**。
/// ここで縛るのは型では止められない残り —— 「解決を定数に置き換える」形。
final class LiveBridgeAutoStartPhysicalTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// physical は**一覧で解決する**(`SimulatorCatalog.isPhysical(udid:)`)。定数に書き換えると
    /// 実機が常にシミュレータ扱いへ戻るが、両方 Bool なので型検査は通ってしまう
    func testLiveServeResolvesPhysicalFromTheCatalog() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        XCTAssertTrue(code.contains("SimulatorCatalog.isPhysical(udid: udid)"),
                      "makeAutoStarter は UDID を一覧に当てて physical を決める"
                      + "(定数に置き換えると実機のライブ復帰が黙って壊れる)")
    }
}
