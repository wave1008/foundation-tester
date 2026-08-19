// 「画面には出ているのに当たらない」形のうち、**本文が複数ノードに割れている**ときの説明を固定する。
// 受け手報告(2026-08-20): 末尾に見えている「2026年2月18日 改訂」が木では3ノードで、
// `*2026年2月18日*` が両 OS とも空振りした。木を無理に畳むと操作対象を潰すので、
// 木は変えずに「割れている」と言う方針。ここが黙ると、利用者には「在るのに見つからない」としか見えない。

import XCTest
@testable import FTCore

final class SplitTextHintTests: XCTestCase {

    private func element(_ ref: Int, _ label: String, y: Double? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y ?? Double(ref) * 40, width: 300, height: 32), depth: 2)
    }

    func testTellsWhenTheTextIsSplitAcrossSiblings() throws {
        let elements = [element(1, "15. 利用規約の改定"), element(2, "2026年"),
                        element(3, "2月18日"), element(4, "改訂")]
        let hint = try XCTUnwrap(StepExecutor.splitTextHint(
            for: FlowLocator(label: "2026年2月18日"), in: elements),
            "隣り合う2件を繋ぐと一致するのに黙っている")
        XCTAssertTrue(hint.contains("split across 2 elements"), hint)
        XCTAssertTrue(hint.contains("2026年"), hint)
        XCTAssertTrue(hint.contains("2月18日"), hint)
        // **存在しない逃げ道を勧めない**: ここへ来た時点で全体を含む要素は木に無い
        // (受け手の実例は表組みの行で、行そのものは要素として出ない)。
        // 「まとめている要素に書け」と言うと、利用者はそれを探して時間を捨てる
        XCTAssertTrue(hint.contains("no single element holds all of it"), hint)
        XCTAssertFalse(hint.contains("the element that contains them"), hint)
    }

    /// 同じ行に横並び(表組みの行)なら、そう言う —— 読み手が「なぜ割れているか」を
    /// 一目で分かるようにするため。受け手の実例: y も高さも同じ 3 セルが x で連続していた
    func testSaysTheyAreOnOneLineWhenTheFramesShareTheirTop() throws {
        let row = [element(1, "2026年", y: 2286), element(2, "2月18日", y: 2286),
                   element(3, "改訂", y: 2286)]
        let hint = try XCTUnwrap(StepExecutor.splitTextHint(
            for: FlowLocator(label: "2026年2月18日"), in: row))
        XCTAssertTrue(hint.contains("one line"), hint)

        let stacked = [element(1, "2026年", y: 100), element(2, "2月18日", y: 400)]
        let other = try XCTUnwrap(StepExecutor.splitTextHint(
            for: FlowLocator(label: "2026年2月18日"), in: stacked))
        XCTAssertFalse(other.contains("one line"), "離れているのに同じ行だと言っている: \(other)")
    }

    /// 空白を挟んで分かれている形(`<b>改訂</b> <span>2026年</span>` 等)も拾う
    func testJoinsWithASpaceToo() throws {
        let elements = [element(1, "2026年2月18日"), element(2, "改訂")]
        let hint = try XCTUnwrap(StepExecutor.splitTextHint(
            for: FlowLocator(label: "2026年2月18日 改訂"), in: elements))
        XCTAssertTrue(hint.contains("split across 2 elements"), hint)
    }

    /// **素で当たるものがあるときは黙る** —— そちらは近傍候補・部分一致ヒントの領分で、
    /// ここが喋ると失敗メッセージが二重に long くなる
    func testStaysSilentWhenAPlainMatchExists() {
        let elements = [element(1, "2026年2月18日 改訂"), element(2, "2026年"), element(3, "2月18日")]
        XCTAssertNil(StepExecutor.splitTextHint(for: FlowLocator(label: "2026年2月18日"),
                                                in: elements))
    }

    /// **偶然の連結で当たらないこと**: 繋ぐ件数に上限があり、離れた要素は繋がない
    func testDoesNotStitchArbitrarilyManyElements() {
        let elements = (1...8).map { element($0, "部分\($0)") }
        XCTAssertNil(StepExecutor.splitTextHint(
            for: FlowLocator(label: "部分1部分2部分3部分4部分5"), in: elements),
            "5件を繋いで当てている(上限が効いていない)")
    }

    /// ラベル指定でないとき(id 指定など)は黙る
    func testStaysSilentWithoutALabelTarget() {
        XCTAssertNil(StepExecutor.splitTextHint(for: FlowLocator(id: "terms_date"),
                                                in: [element(1, "2026年"), element(2, "2月18日")]))
    }
}
