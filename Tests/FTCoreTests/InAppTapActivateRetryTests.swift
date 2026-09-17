// in-app の ref タップで activate が不発のときの撃ち直しを、自前描画のアプリに限ることを守る。
// 撃ち直しが効いた実測は Compose だけで、UIKit / SwiftUI / RN では毎回 約 0.4 秒を払うだけだった
// (AppUIFramework.retriesUnfiredActivate)。in-app の dylib は swift test でリンクされないので、
// 配線はソースを走査して守る。

import XCTest
import FTCore

final class InAppTapActivateRetryTests: XCTestCase {

    func testOnlySelfRenderedFrameworksRetryUnfiredActivate() {
        let expected: [AppUIFramework: Bool] = [
            .compose: true, .flutter: true,
            .reactNative: false, .swiftUI: false, .uikit: false, .androidView: false,
        ]
        XCTAssertEqual(Set(expected.keys), Set(AppUIFramework.allCases), "語彙を足したら表にも足す")
        for (framework, retries) in expected {
            XCTAssertEqual(framework.retriesUnfiredActivate, retries, "\(framework)")
        }
    }

    private func tapByRefBody() throws -> Substring {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        guard let start = bridge.range(of: "private func tapByRef("),
              let end = bridge.range(of: "private func refreshedNode(", range: start.upperBound..<bridge.endIndex)
        else {
            XCTFail("tapByRef / refreshedNode が見つかりません")
            return ""
        }
        return bridge[start.lowerBound..<end.lowerBound]
    }

    /// tapByRef が判定を読み、撃ち直しの前で分岐していること
    func testTapByRefGatesTheRetryOnTheFramework() throws {
        let body = try tapByRefBody()
        XCTAssertTrue(body.contains("AppUIFramework(rawValue: uiFramework)?.retriesUnfiredActivate ?? true"),
                      "tapByRef が AppUIFramework.retriesUnfiredActivate を読んでいません(不明は撃ち直す側)")
        guard let gate = body.range(of: "guard retriesUnfiredActivate else"),
              let retry = body.range(of: "retry(2, stale: node, window: window)") else {
            return XCTFail("撃ち直しの分岐か retry(2) の呼び出しが見つかりません")
        }
        XCTAssertLessThan(gate.lowerBound, retry.lowerBound, "分岐は撃ち直しの前に置く")
    }

    /// 撃ち直さない経路も、整定を待ってから合成タッチすること(回転の遷移中はタッチが捨てられる。
    /// 「位置が動いたときだけ待つ」にしたら E2E-RN の回転直後の tap が吸われた)
    func testNonRetryPathSettlesBeforeTheSyntheticTouch() throws {
        let body = try tapByRefBody()
        guard let start = body.range(of: "func synthAtCurrentFrame("),
              let end = body.range(of: "func retry(", range: start.upperBound..<body.endIndex) else {
            return XCTFail("synthAtCurrentFrame が見つかりません")
        }
        let path = body[start.lowerBound..<end.lowerBound]
        guard let settle = path.range(of: "InAppSettle.waitOnMain("),
              let touch = path.range(of: "synthFallback(") else {
            return XCTFail("整定待ちか合成タッチが見つかりません")
        }
        XCTAssertLessThan(settle.lowerBound, touch.lowerBound, "合成タッチは整定の後")
        XCTAssertEqual(path.components(separatedBy: "synthFallback(").count - 1, 1,
                       "整定を通らずに合成タッチへ落ちる枝を作らない")
    }

    /// 撃ち直さない経路も、取り直した現在 frame で撃つこと(RN のコールドラウンチでレイアウト確定前の
    /// frame を叩いた実害)
    func testNonRetryPathStillAdoptsTheCurrentFrame() throws {
        let body = try tapByRefBody()
        guard let start = body.range(of: "func synthAtCurrentFrame("),
              let end = body.range(of: "func retry(", range: start.upperBound..<body.endIndex) else {
            return XCTFail("synthAtCurrentFrame が見つかりません")
        }
        let path = body[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(path.contains("refreshedNode(matching:"), "取り直しを消さない")
        XCTAssertTrue(path.contains("adoptFreshFrame("), "取り直した frame を座標に採る")
        XCTAssertFalse(path.contains("accessibilityActivate"), "この経路では activate を撃ち直さない")
    }
}
