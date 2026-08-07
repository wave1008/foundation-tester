// `ElementInfo` の Codable 往復。
//
// **なぜ要るか**: encode は合成なのに `init(from:)` だけ手書きという非対称があり、
// フィールドを足すと**送られてはいるのに常に nil で読める**状態が黙って生まれる。
// 2026-08-07 に `z`(塗り順)で実際に踏んだ —— ブリッジは出しているのにホストが読まず、
// 遮蔽の警告が出ないまま「修正が効かない」ように見えた(実装は正しかった)。
//
// **フィールドを列挙しない**のが要点。Mirror で全項目を突き合わせるので、
// 新しいフィールドを足してデコードを書き忘れれば**このテストを触らなくても落ちる**。

import XCTest
@testable import FTCore

final class ElementInfoCodingTests: XCTestCase {

    /// 全項目に「既定値と違う値」を入れた1件。optional は**すべて非 nil**にする
    /// (nil のままだと「読まれていない」と「元から nil」が区別できない)
    private func fullyPopulated() -> ElementInfo {
        ElementInfo(
            ref: 42,
            // **正規化済みの型名を渡す**: decode 側は先頭を小文字化するので、
            // "Button" を入れると往復で必ず食い違い、本題(読み落とし)が埋もれる
            type: "button",
            identifier: "search_omnibox_text_box",
            label: "ここで検索",
            value: "東京タワー",
            placeholder: "ここで検索",
            enabled: false,
            frame: FTRect(x: 31, y: 163, width: 758, height: 126),
            depth: 7,
            checked: true,
            web: true,
            focused: true,
            scrollable: true,
            z: 124)
    }

    func testEveryFieldSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = fullyPopulated()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ElementInfo.self, from: data)

        let before = Dictionary(uniqueKeysWithValues: Mirror(reflecting: original).children
            .compactMap { child -> (String, String)? in
                guard let name = child.label else { return nil }
                return (name, String(describing: child.value))
            })
        let after = Dictionary(uniqueKeysWithValues: Mirror(reflecting: decoded).children
            .compactMap { child -> (String, String)? in
                guard let name = child.label else { return nil }
                return (name, String(describing: child.value))
            })

        XCTAssertFalse(before.isEmpty, "Mirror が1項目も取れていない(テストが無力)")
        for (name, value) in before {
            XCTAssertEqual(after[name], value,
                           "\(name) が往復で失われた。encode は合成・decode は手書きなので、"
                           + "`ElementInfo.init(from:)` に decodeIfPresent を足すこと")
        }
    }

    /// 送られてきた JSON に**キーがある**のに読み落としていないか。上の往復テストと合わせて
    /// 「合成 encode → 手書き decode」の穴を塞ぐ(ブリッジは Swift の encoder を通さない
    /// 実装[Android は org.json]なので、キー名の綴り違いはここでしか落ちない)
    func testDecoderReadsEveryKeyTheEncoderWrites() throws {
        let data = try JSONEncoder().encode(fullyPopulated())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(ElementInfo.self, from: data)
        let read = Set(Mirror(reflecting: decoded).children.compactMap(\.label))
        for key in json.keys {
            XCTAssertTrue(read.contains(key), "JSON の \(key) に対応するプロパティが無い")
        }
        // 逆向き: プロパティがあるのに JSON へ出ていない = encode 側の漏れ
        for name in read {
            XCTAssertNotNil(json[name], "\(name) が JSON へ出ていない")
        }
    }
}
