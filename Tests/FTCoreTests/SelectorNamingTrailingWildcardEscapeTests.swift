import XCTest
@testable import FTCore

/// `SelectorNaming.needsEscaping` は先頭の `*`(startsWith 記法)は逃がすが、末尾の `*` を
/// 見ていなかった。ラベル "Save*" は `FTSelector.parse` が startsWith("Save") と読み、
/// serialize が同じ文字列 "Save*" を返す(綴りが往復する)ため、②の綴り往復チェックを
/// すり抜けて false になっていた —— だが実際に書きたいのは「完全一致 "Save*"」であって
/// 「"Save" で始まる」ではないので、素のまま勧めると別要素へ解決し得る誤ったセレクタになる
final class SelectorNamingTrailingWildcardEscapeTests: XCTestCase {

    func testTrailingAsteriskNeedsEscaping() {
        XCTAssertTrue(SelectorNaming.needsEscaping("Save*"))
    }

    func testLeadingAsteriskStillNeedsEscaping() {
        XCTAssertTrue(SelectorNaming.needsEscaping("*Save"))
    }

    func testPlainLabelDoesNotNeedEscaping() {
        XCTAssertFalse(SelectorNaming.needsEscaping("Save"))
    }

    /// 実際に勧めるセレクタが `=Save*`(escaped literal)になることを end-to-end で確かめる。
    /// **もう1要素("Save now")を混ぜて確かめる**必要がある —— 木に1要素しか無いと、
    /// 素のまま(startsWith "Save" と解釈される)でも「候補は1件」になってしまい、
    /// 素の形が先に候補へ入るので escape 無しでも偶然 `picksOnlyOne` を満たしてしまう
    /// (needsEscaping の直しが効いたかを見分けられない)。2件目があると、素のままの
    /// startsWith は両方に一致して曖昧になり、`=` エスケープ(完全一致)だけが1件に絞れる
    func testGradedRecommendsEscapedLiteralForTrailingAsteriskLabel() {
        let target = ElementInfo(ref: 1, type: "button", identifier: nil, label: "Save*",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)
        let decoy = ElementInfo(ref: 2, type: "button", identifier: nil, label: "Save now",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 50, width: 100, height: 40), depth: 0)
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [target, decoy], truncatedCount: 0)
        let naming = SelectorNaming(snapshot)

        let selector = naming.selector(for: target, in: snapshot)

        XCTAssertEqual(selector, "=Save*")
    }
}
