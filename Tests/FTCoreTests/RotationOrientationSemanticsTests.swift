// 回転の契約: **アプリの UI がその向きになること**(デバイスがどう傾いているかではない)。
//
// テストが観測できるのは frame と画面サイズだけで、それは iOS も Android も、
// Compose / SwiftUI / View-XML / Flutter / React Native のどれでも**アプリ座標系**で返る。
// だから「アプリの向き」だけが跨いで同じ意味を持つ —— 物理的な左右は観測できないので約束しない
// (2026-08-10 ユーザー決定。経緯は FTOrientation の宣言と docs/design.md)。
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

    /// Android の判定は「窓が横長か」。これは契約(アプリの向き)そのもので、
    /// `dumpsys display` の角度ではない —— 表示だけ回ってアプリが縦のままの形を成功にしない
    func testAndroidSettlesOnTheAppWindowNotTheDisplayAngle() throws {
        let driver = try source("Sources/FTAndroid/AndroidDriver.swift")
        XCTAssertTrue(driver.contains("(screen.width > screen.height) == wantsLandscape"),
                      "Android の整定はスナップショットの画面サイズで判定すること")
    }
}
