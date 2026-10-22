// in-app ブリッジのジェスチャ経路が「黙って無反応」に戻らないことを守る。
//
// 事情(2026-08-04 に4 SUT で実測):
//   - XCUITest の doubleTap は「離してから次に押すまで」が 0ms で、Compose(iOS)が2打目を捨てる
//   - XCUITest の pinch は指の間隔を 8px 程度しか開かず、Flutter のスケール判定に届かない
//   - in-app は間隔も指の距離も自分で決められるので、その2つが通る(実測で確認)
//   - ただし **UIKit/SwiftUI では合成タッチを UIGestureRecognizer が受理しない**ので、
//     in-app が 200 を返すと黙って無反応になる → 501 を返して XCUITest へ回す必要がある
//
//   - 座標ドラッグも同じ(2026-10-22): XCUITest の合成では負荷下で Compose が最後の移動を捨て、in-app の実時間の
//     ドラッグ(FTSynthDrag)なら位置も速度も届く。UIKit/SwiftUI は 501 で XCUITest へ
//
// この振り分けが失われると**エンジンによって効いたり効かなかったりする無音の退行**になる。
// E2E はエンジンで分岐できない(同じシナリオが両プロファイルで走る)ため、ここでソースを走査して守る。

import XCTest
import FTCore

final class InAppGestureRoutingTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// in-app ブリッジが2つのルートを持つこと(無ければ 404 → 常に XCUITest 経由に戻る)
    func testInAppBridgeServesGestureRoutes() throws {
        let bridge = try source("InAppBridge/Sources/InAppBridge.swift")
        XCTAssertTrue(bridge.contains("(\"POST\", \"/doubletap\")"),
                      "in-app ブリッジが /doubletap を失っています(Compose の doubleTap が単タップに戻る)")
        XCTAssertTrue(bridge.contains("(\"POST\", \"/pinch\")"),
                      "in-app ブリッジが /pinch を失っています(Flutter のピンチが効かなくなる)")
        XCTAssertTrue(bridge.contains("(\"POST\", \"/drag\")"),
                      "in-app ブリッジが /drag を失っています(Compose の払いきりが XCUITest の合成に戻り、最後の移動を捨てる)")
    }

    /// 両ハンドラが**自前描画フレームワークに限定**していること。
    /// この判定を外すと UIKit/SwiftUI で 200 を返しながら何も起きない(無音の失敗)
    func testInAppGestureHandlersRejectUIKit() throws {
        let bridge = try source("InAppBridge/Sources/InAppBridge.swift")
        for handler in ["handleDoubleTap", "handlePinch", "handleDrag"] {
            guard let range = bridge.range(of: "private func \(handler)") else {
                return XCTFail("\(handler) が見つかりません")
            }
            // ハンドラ本体(次の空行+インデント終わりまで見ずに、十分な窓で判定する)
            let body = bridge[range.lowerBound...].prefix(1200)
            XCTAssertTrue(body.contains("requireSelfRenderedFramework"),
                          "\(handler) がフレームワーク判定を通していません。"
                              + "UIKit/SwiftUI では合成タッチが受理されないため、"
                              + "501 を返して XCUITest へ回さないと黙って無反応になります")
        }
        // in-app はアプリのプロセスに載るので、上限を超えた秒数で刻みを作るとアプリごと落ちる(XCUITest の /drag と同じ絶対上限)
        for (handler, what) in [("handleDrag", "drag"), ("handlePinch", "pinch")] {
            guard let range = bridge.range(of: "private func \(handler)") else {
                XCTFail("\(handler) が見つかりません(改名したら走査の名前も直す)"); continue
            }
            XCTAssertTrue(bridge[range.lowerBound...].prefix(1800).contains("BridgeAPI.gestureDurationViolation(\"\(what)\""),
                          "\(handler) が秒数の絶対上限を検査していません")
        }
        XCTAssertTrue(bridge.contains("[\"compose\", \"flutter\"].contains(uiFramework)"),
                      "requireSelfRenderedFramework の判定対象が変わっています")
    }

    /// InAppDriver が2つの操作をブリッジへ素通しすること(ローカルで 501 を投げると
    /// 実装したルートに届かないまま XCUITest へ回り続ける)
    func testInAppDriverForwardsGestures() throws {
        let driver = try source("Sources/FTBridgeClient/InAppDriver.swift")
        XCTAssertTrue(driver.contains("client.doubleTap(x: x, y: y)"),
                      "InAppDriver が doubleTap をブリッジへ渡していません")
        XCTAssertTrue(driver.contains("client.pinch(request:"),
                      "InAppDriver が pinch をブリッジへ渡していません")
        XCTAssertTrue(driver.contains("client.drag(fromX: fromX"),
                      "InAppDriver が drag をブリッジへ渡していません(自前描画のドラッグが XCUITest の合成に戻る)")
        XCTAssertTrue(driver.contains("PinchGesture.ios(frame: frame"),
                      "InAppDriver が指の置き方を PinchGesture.ios に委ねていません(ホストが指を組んで fingers で送る)")
    }
}
