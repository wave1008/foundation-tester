// 回転の契約: **アプリの UI がその向きになること**(デバイスがどう傾いているかではない)。
//
// テストが観測できるのは frame と画面サイズだけで、それは iOS も Android も、
// Compose / SwiftUI / View-XML / Flutter / React Native のどれでも**アプリ座標系**で返る。
// だから「アプリの向き」だけが跨いで同じ意味を持つ —— 物理的な左右は観測できないので約束しない
// (ユーザー決定。経緯は FTOrientation の宣言と docs/design.md)。
//
// この決定は3つの実装に同時に効くので、ブリッジのソース走査で対応表を固定する
// (ブリッジは別ターゲットで単体テストから呼べない。BridgeContractTests と同じ流儀)。

import XCTest
import FTCore

final class RotationOrientationSemanticsTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// **語彙は2値**。左右を足し戻す変更をここで落とす(足すなら、観測できない区別を
    /// どう検証するかを先に決めること)
    func testVocabularyIsExactlyPortraitAndLandscape() {
        XCTAssertEqual(Set(FTOrientation.allCases.map(\.rawValue)), ["portrait", "landscape"])
    }

    func testParseAcceptsOnlyTheTwoValues() {
        XCTAssertEqual(FTOrientation.parse("portrait"), .portrait)
        XCTAssertEqual(FTOrientation.parse("landscape"), .landscape)
        XCTAssertNil(FTOrientation.parse("landscapeLeft"), "廃止した名前を黙って受けない")
        XCTAssertNil(FTOrientation.parse("Landscape"), "大文字小文字は揺らさない")
        XCTAssertNil(FTOrientation.parse(""))
    }

    /// **読み側は左右をまとめる**。片側しか landscape と認めないと、OS がもう一方を選んだ回に
    /// 整定が永久に一致せず 422 になる(要求と同じ側かは契約に無い)
    func testBothBridgesReadEitherLandscapeAsLandscape() throws {
        for path in ["Runner/FTesterRunnerUITests/BridgeRouter.swift",
                     "InAppBridge/Sources/InAppBridge.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("case .landscapeLeft, .landscapeRight: return .landscape"),
                          "\(path): 左右どちらも landscape として読むこと")
        }
    }

    /// **3実装とも「アプリの窓」で判定する**。表示やデバイスの向きで判定すると、
    /// 縦向き専用のアプリで**回っていないのに成功を返す**(2026-08-10 に xcuitest で実測)
    func testEveryImplementationSettlesOnTheAppWindow() throws {
        let android = try source("Sources/FTAndroid/AndroidDriver.swift")
        XCTAssertTrue(android.contains("(screen.width > screen.height) == wantsLandscape"),
                      "Android はスナップショットの画面サイズで判定すること")

        let runner = try source("Runner/FTesterRunnerUITests/BridgeRouter.swift")
        XCTAssertTrue(runner.contains("if appOrientation() == req.orientation"),
                      "XCUITest はアプリの窓で判定すること(XCUIDevice の向きではない)")
        XCTAssertFalse(runner.contains("if XCUIDevice.shared.orientation.ftOrientation == req.orientation"),
                       "デバイスの向きでの判定に戻っている(縦専用アプリで偽の成功になる)")

        let inApp = try source("InAppBridge/Sources/InAppBridge.swift")
        XCTAssertTrue(inApp.contains("interfaceOrientation.ftOrientation"),
                      "in-app はシーンの interfaceOrientation(= アプリの向き)で判定すること")
    }
}
