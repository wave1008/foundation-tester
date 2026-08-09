import XCTest

@testable import FTCore

/// 不可視文字を挟んでも一致すること。**`matches` の既定は `.selector`**(この関数は
/// セレクタのフィルタから呼ばれる)。テキストと期待値の比較は `.text` で、規則が違う ——
/// 両者の違いは TextNormalizationTests が固定する。
/// 同期対象: SnapshotRenderer.renderElement が同じ正規化(`.text`)を出力へ通す。
final class FlowMatchModeTests: XCTestCase {
    private let zwLabel = "\u{200B}\u{200B}中央線\u{200D}\u{FEFF}\u{2060}"

    func testExactMatchIgnoresZeroWidthCharactersInActualAndExpected() {
        XCTAssertTrue(FlowMatchMode.exact.matches(zwLabel, "中央線"))
        XCTAssertTrue(FlowMatchMode.exact.matches("中央線", zwLabel))
    }

    func testContainsMatchIgnoresZeroWidthCharacters() {
        XCTAssertTrue(FlowMatchMode.contains.matches(zwLabel, "央線"))
    }

    /// .matches は正規表現なので expected 側は正規化しない(パターンを書き換えないため)。
    /// actual 側だけ正規化されれば素のパターンで一致する
    func testRegexMatchNormalizesActualOnlyNotPattern() {
        XCTAssertTrue(FlowMatchMode.matches.matches(zwLabel, "中央線"))
        XCTAssertTrue(FlowMatchMode.matches.matches(zwLabel, "中央線", normalization: .text))
    }

    func testExactMatchStillFailsOnRealDifference() {
        XCTAssertFalse(FlowMatchMode.exact.matches(zwLabel, "中央本線"))
    }

    // MARK: - 幅のある不可視空白(NBSP)

    /// 実データ(2026-08-09・Google マップ Android の路線ラベル)。
    /// 先頭が U+00A0 で、印字すると通常空白と見分けが付かない
    private static let nbspLabel = "\u{00A0} 埼京線"

    /// **除去ではなく正規化**: 通常空白で打ち直したセレクタが一致すること。
    /// これが受け入れ条件そのもの(印字された文字列をそのまま書いたら当たる)。
    /// セレクタ側は両端トリムも効くので、トリム済みで書いても当たる
    func testNoBreakSpaceIsNormalizedToAPlainSpace() {
        XCTAssertTrue(FlowMatchMode.exact.matches(Self.nbspLabel, "  埼京線"))
        XCTAssertTrue(FlowMatchMode.exact.matches(Self.nbspLabel, "埼京線"))
        XCTAssertTrue(FlowMatchMode.exact.matches(Self.nbspLabel, "  埼京線",
                                                  normalization: .text))
        XCTAssertTrue(FlowMatchMode.contains.matches(Self.nbspLabel, " 埼京線"))
    }

    /// **除去したら別の一致崩れを作る**: `"A B"` が `"AB"` になってはいけない
    func testNoBreakSpaceKeepsItsColumn() {
        XCTAssertEqual(FlowMatchMode.normalizeInvisibleCharacters("A\u{00A0}B"), "A B")
        XCTAssertFalse(FlowMatchMode.exact.matches("A\u{00A0}B", "AB"))
        XCTAssertFalse(FlowMatchMode.exact.matches("A\u{00A0}B", "AB", normalization: .text))
    }

    /// **全角スペースはテキスト比較では別物**(半角と見た目が違う)。
    /// セレクタ側は「見つける」ためのものなので空白の種類を吸収する = ここだけ挙動が割れる
    func testIdeographicSpaceIsDistinctForTextButFoldedForSelectors() {
        XCTAssertEqual(FlowMatchMode.normalizeInvisibleCharacters("A\u{3000}B"), "A\u{3000}B")
        XCTAssertFalse(FlowMatchMode.exact.matches("A\u{3000}B", "A B", normalization: .text))
        XCTAssertTrue(FlowMatchMode.exact.matches("A\u{3000}B", "A B", normalization: .selector))
    }

    /// ゼロ幅(除去)と NBSP(正規化)が**1回の走査で両方**通ること。
    /// 別処理に割れると、片方だけ通った文字列が生まれる
    func testZeroWidthAndSpaceLikeAreNormalizedTogether() {
        XCTAssertEqual(FlowMatchMode.normalizeInvisibleCharacters("\u{00A0}\u{200B}埼京線\u{200B}"),
                       " 埼京線")
    }

    /// 正規表現のパターンは書き換えない(従来どおり actual だけ正規化)。
    /// **セレクタ側は両端をトリムする**ので、先頭の空白を要求するパターンは当たらなくなる ——
    /// 「見つける」側の寛容さの裏返しで、意図した挙動
    func testRegexPatternIsNotNormalized() {
        XCTAssertTrue(FlowMatchMode.matches.matches(Self.nbspLabel, "^ +埼京線$",
                                                    normalization: .text))
        XCTAssertTrue(FlowMatchMode.matches.matches(Self.nbspLabel, "^埼京線$",
                                                    normalization: .selector))
    }
}

/// **描画側と照合側が同じ正規化を通ることの固定**(A-3)。
/// この2つがズレると「木に出ている文字列をそのまま写したのに当たらない」= 照合のバグに見える
/// 症状になる。片方だけ変えられないようにここで縛る。
final class RenderedLabelRoundTripTests: XCTestCase {

    private func element(label: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
    }

    /// 印字された行からラベルを切り出して exact セレクタに使うと必ず当たる
    private func assertRoundTrips(_ raw: String, file: StaticString = #filePath, line: UInt = #line) {
        let rendered = SnapshotRenderer.renderElement(element(label: raw))
        guard let start = rendered.firstIndex(of: "\""),
              let end = rendered.lastIndex(of: "\""), start < end else {
            return XCTFail("ラベルが印字されていない: \(rendered)", file: file, line: line)
        }
        let printed = String(rendered[rendered.index(after: start)..<end])
        XCTAssertTrue(FlowMatchMode.exact.matches(raw, printed),
                      "印字 \"\(printed)\" が生ラベル \(raw.debugDescription) に一致しない",
                      file: file, line: line)
    }

    /// **印字された文字列に不可視文字が残っていないこと**を直接見る。
    /// マッチだけで確かめると `matches` が expected 側も正規化するので、
    /// **描画側の正規化を外しても素通しする**(2026-08-09 の変異テストで実際に素通しした)。
    /// 読み手は印字を見て手で打ち直すので、印字そのものが正規化済みでなければ意味が無い
    private func assertPrintedIsNormalized(_ raw: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let rendered = SnapshotRenderer.renderElement(element(label: raw))
        for scalar in rendered.unicodeScalars {
            XCTAssertFalse(FlowMatchMode.zeroWidthScalars.contains(scalar),
                           "印字に U+\(String(scalar.value, radix: 16)) が残っている: \(rendered.debugDescription)",
                           file: file, line: line)
            XCTAssertFalse(FlowMatchMode.spaceLikeScalars.contains(scalar),
                           "印字に U+\(String(scalar.value, radix: 16)) が残っている: \(rendered.debugDescription)",
                           file: file, line: line)
        }
    }

    func testPrintedLabelCarriesNoInvisibleCharacters() {
        assertPrintedIsNormalized("\u{00A0} 埼京線")
        assertPrintedIsNormalized("\u{200B}\u{200B}中央線\u{200B}")
        assertPrintedIsNormalized("\u{00A0}\u{200B}混在\u{FEFF}")
    }

    func testPrintedLabelAlwaysMatchesTheRawOne() {
        assertRoundTrips("\u{00A0} 埼京線")          // NBSP(実データ)
        assertRoundTrips("\u{200B}\u{200B}中央線\u{200B}")  // ゼロ幅(実データ)
        assertRoundTrips("\u{00A0}\u{200B}混在\u{FEFF}")
        assertRoundTrips("ふつうのラベル")
        assertRoundTrips("A\u{3000}B")               // 全角スペースは素通し
    }

    /// **実アプリのコーパス全数**に当てる(自前の例だけだと想定した形しか試せない)
    func testEveryLabelInTheRealAppCorpusRoundTrips() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertFalse(files.isEmpty, "コーパスが空 — このテストは何も検証していない")
        for file in files {
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            let snapshot = try JSONDecoder().decode(SnapshotResponse.self, from: data)
            for element in snapshot.elements {
                guard let label = element.label, !label.isEmpty else { continue }
                let printed = FlowMatchMode.normalizeInvisibleCharacters(label)
                guard printed.count <= SnapshotRenderer.labelDisplayLimit else { continue }
                XCTAssertTrue(FlowMatchMode.exact.matches(label, printed),
                              "\(file): 印字 \"\(printed)\" が生ラベル \(label.debugDescription) に一致しない")
                for scalar in printed.unicodeScalars {
                    XCTAssertFalse(FlowMatchMode.zeroWidthScalars.contains(scalar)
                                   || FlowMatchMode.spaceLikeScalars.contains(scalar),
                                   "\(file): 印字に不可視文字が残っている \(printed.debugDescription)")
                }
            }
        }
    }
}
