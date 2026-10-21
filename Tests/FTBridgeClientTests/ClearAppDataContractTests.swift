// clearAppData(iOS シミュレータ)が**2段とも**残っていることをソース走査で守る。
//
// ファイルを消すだけでは NSUserDefaults が戻ってくる(cfprefsd がドメインを抱えており、
// 次の起動で消したはずの値を配って plist を書き直す)。**この欠落は黙って通る** ——
// 消去は成功を返し、アプリは前回の状態で立ち上がるだけなので、シナリオ側は
// 「clearAppData から始めたのに前回の状態が残っている」を踏むまで気付けない
// (2026-08-05 の実測: 消して起動を3回で launch_count が 2→3→4 と増え続けた)。
//
// 挙動そのものは実機(シミュレータ)でしか確かめられないので、ここでは
// **手順が落ちていないこと**だけを見る。

import XCTest

final class ClearAppDataContractTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testClearingTheContainerAlsoDropsThePreferencesCache() throws {
        let bridgeClient = try source("Sources/FTBridgeClient/BridgeClient.swift")
        guard let range = bridgeClient.range(of: "func clearAppDataOnSimulator") else {
            return XCTFail("clearAppDataOnSimulator が見つからない(改名したらこのテストも直す)")
        }
        // **コメントを落としてから見る**: 理由書きに cfprefsd と書いてあるので、
        // そのまま走査すると**手順を消してもコメントだけで緑になる**(実際に一度そうなった)
        let body = String(bridgeClient[range.lowerBound...].prefix(5_000))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(body.contains("removeItem"),
                      "データコンテナの中身を消す手順が落ちている")
        XCTAssertTrue(body.contains("kickstart") && body.contains("cfprefsd"),
                      "cfprefsd を入れ直す手順が落ちている = UserDefaults が消去を生き延びる"
                      + "(消去は成功を返すので黙って通る)")
        XCTAssertTrue(body.contains("resetPrivacyOnSimulator"),
                      "権限リセットが落ちている(権限はコンテナの外にある)")
        // **消す前に simctl で終了する**: ランナーの terminate はセッションの外で起動したアプリに効かず、
        // 動いたままのアプリの下で消すと状態が書き戻る(実測: Apple マップが同じ pid のまま残り、前回の経路が出た)
        let stop = body.range(of: "stopOnSimulator(")
        let remove = body.range(of: "removeItem")
        XCTAssertNotNil(stop, "消す前の simctl terminate が落ちている = 動いているアプリの下でファイルを消す")
        if let stop, let remove {
            XCTAssertLessThan(stop.lowerBound, remove.lowerBound, "終了より先に消している")
        }
    }

    /// `stopOnSimulator` 自身が simctl terminate を撃ち、終了コードで分ける(0 = 止めた / 3 = 動いていなかった)
    func testStopOnSimulatorUsesSimctlTerminateAndTheExitCode() throws {
        let bridgeClient = try source("Sources/FTBridgeClient/BridgeClient.swift")
        guard let range = bridgeClient.range(of: "public static func stopOnSimulator") else {
            return XCTFail("stopOnSimulator が見つからない(改名したらこのテストも直す)")
        }
        // 公開の口は本体(terminate を差し替えられる overload)へ委ねるので、両方を含む範囲を見る
        let body = String(bridgeClient[range.lowerBound...].prefix(5000))
        XCTAssertTrue(body.contains("\"simctl\", \"terminate\""), body)
        XCTAssertTrue(body.contains("stop.status == 0 || stop.status == 3"), body)
    }
}
