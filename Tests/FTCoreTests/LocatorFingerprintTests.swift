import XCTest
@testable import FTCore

/// `LocatorFingerprint.resolve(in:)` の純粋ロジック(指紋 → 木 → 0/1/複数)だけを直接叩く。
/// デバイスも FM も要らない(ElementInfo の配列を組み立てるだけ)。
/// **最重要の陰性テストは2件一致**: 別要素へ静かに解決する退行(「常に解決する」変異)を
/// ここで落とす。「決して解決しない」変異は一致1件のテストが落とす。
final class LocatorFingerprintTests: XCTestCase {

    private func element(_ ref: Int, type: String, label: String?,
                         placeholder: String? = nil, id: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: placeholder, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)
    }

    func testUniqueMatchResolves() {
        let target = element(1, type: "button", label: "修復対象")
        let other = element(2, type: "button", label: "別のボタン")
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        XCTAssertEqual(fp.resolve(in: [target, other])?.ref, 1)
    }

    func testNoMatchDoesNotResolve() {
        let elements = [element(1, type: "button", label: "別のボタン")]
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        XCTAssertNil(fp.resolve(in: elements),
                     "0件一致は不採用のまま(従来経路=FM ヒールへ委ねる)でなければならない")
    }

    /// **最重要**: 型+ラベルが同じ要素が2つ以上あるとき、どちらか一方を勝手に選んではいけない。
    /// 選ぶと別要素へ静かに解決し、後段の検証が別要素を見て誤った緑/誤った赤を作る
    func testMultipleMatchesDoNotResolve() {
        let a = element(1, type: "button", label: "修復対象")
        let b = element(2, type: "button", label: "修復対象")
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        XCTAssertNil(fp.resolve(in: [a, b]),
                     "複数件一致を「もっとも近い」等のスコアで選んではいけない")
    }

    /// type が違えば label が同じでも別要素として扱う(type と label は論理積)
    func testDifferentTypeWithSameLabelDoesNotMatch() {
        let target = element(1, type: "button", label: "修復対象")
        let differentType = element(2, type: "cell", label: "修復対象")
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        XCTAssertEqual(fp.resolve(in: [target, differentType])?.ref, 1)
    }

    /// label が nil の指紋は、label も nil の要素とだけ一致し得る(nil==nil を「一致」として扱う。
    /// 一意性ゲートがあるので複数あれば結局不採用になる)
    func testNilLabelFingerprintMatchesOnlyNilLabelElement() {
        let noLabel = element(1, type: "cell", label: nil)
        let withLabel = element(2, type: "cell", label: "何か")
        let fp = LocatorFingerprint(type: "cell", label: nil, placeholder: nil)

        XCTAssertEqual(fp.resolve(in: [noLabel, withLabel])?.ref, 1)
    }

    /// placeholder は**非 nil のときだけ**照合に加える。指紋が placeholder を持たなければ
    /// 現在の要素の placeholder が何であっても無視する(過剰な足切りをしない)
    func testNilPlaceholderInFingerprintIsIgnoredDuringMatch() {
        let elementWithPlaceholder = element(1, type: "textField", label: "メール", placeholder: "you@example.com")
        let fp = LocatorFingerprint(type: "textField", label: "メール", placeholder: nil)

        XCTAssertEqual(fp.resolve(in: [elementWithPlaceholder])?.ref, 1)
    }

    /// placeholder が指紋に控えられているときは、現在の要素の placeholder と食い違えば不一致
    func testNonNilPlaceholderMustMatch() {
        let sameLabelDifferentPlaceholder = element(1, type: "textField", label: "メール",
                                                     placeholder: "different@example.com")
        let fp = LocatorFingerprint(type: "textField", label: "メール", placeholder: "you@example.com")

        XCTAssertNil(fp.resolve(in: [sameLabelDifferentPlaceholder]))
    }

    /// `init(of:)` は id/value を持ち込まない(id はドリフトで変わる本人、value は実行ごとに変わる)
    func testInitOfElementDoesNotCaptureIDOrValue() {
        var e = element(1, type: "button", label: "修復対象", id: "btn_old")
        e.value = "何かの値"
        let fp = LocatorFingerprint(of: e)

        XCTAssertEqual(fp.type, "button")
        XCTAssertEqual(fp.label, "修復対象")
        // LocatorFingerprint に id/value を保持するプロパティが無いことは型定義そのものが保証する
        // (struct に id/value フィールドを足す変異が入れば、このファイルはコンパイルの時点で
        // 何も検出できないが、以下は「controlled な属性以外は使わない」ことを resolve 側で確認する)
        let elsewhereWithDifferentIDAndValue = element(2, type: "button", label: "修復対象", id: "btn_new")
        XCTAssertEqual(fp.resolve(in: [elsewhereWithDifferentIDAndValue])?.ref, 2,
                       "id が変わっても(ドリフトそのもの)、value が無くても一致するはず")
    }
}
