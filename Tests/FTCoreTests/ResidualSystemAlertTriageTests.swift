import XCTest
@testable import FTCore

/// run 開始時の残留アラート検知。**警告のためのもの**なので、候補ボタンを漏らさず見せることと、
/// アラートが無い画面で鳴らないことの両方を固定する
final class ResidualSystemAlertTriageTests: XCTestCase {

    private func element(_ type: String, _ label: String?, depth: Int) -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: depth)
    }

    func testアラートの題と候補ボタンを両方出す() {
        let tree = [
            element("alert", "“アプリ”に位置情報の使用を許可しますか?", depth: 1),
            element("staticText", "説明", depth: 2),
            element("button", "許可しない", depth: 2),
            element("button", "Appの使用中は許可", depth: 2),
        ]
        let described = ResidualSystemAlertTriage.describe(elements: tree)
        guard let described else { return XCTFail("検知を期待") }
        XCTAssertTrue(described.contains("位置情報"), described)
        XCTAssertTrue(described.contains("許可しない"), described)
        XCTAssertTrue(described.contains("Appの使用中は許可"), described)
    }

    func testアラートが無ければ黙る() {
        let tree = [element("button", "ホーム", depth: 1), element("staticText", "12:00", depth: 1)]
        XCTAssertNil(ResidualSystemAlertTriage.describe(elements: tree))
    }

    /// アラートの外側にあるボタン(ホーム画面のアイコン等)を候補に混ぜない。
    /// **境界は「アラートと同じ depth の兄弟」**: そこで打ち切らないと、木の後ろに続く
    /// 画面全体のボタンを「このアラートの選択肢」として並べてしまう
    func testアラートの外のボタンは候補に入れない() {
        let tree = [
            element("alert", "許可しますか?", depth: 2),
            element("button", "許可", depth: 3),
            element("button", "同じ深さの兄弟", depth: 2),
            element("button", "浅いところのボタン", depth: 1),
        ]
        let described = ResidualSystemAlertTriage.describe(elements: tree)
        guard let described else { return XCTFail("検知を期待") }
        XCTAssertTrue(described.contains("許可"), described)
        XCTAssertFalse(described.contains("同じ深さの兄弟"), described)
        XCTAssertFalse(described.contains("浅いところのボタン"), described)
    }

    func test題が無いアラートでも検知はする() {
        let tree = [element("alert", nil, depth: 1), element("button", "OK", depth: 2)]
        let described = ResidualSystemAlertTriage.describe(elements: tree)
        XCTAssertNotNil(described)
        XCTAssertTrue(described!.contains("OK"), described!)
    }

    func testボタンが1つも無くても検知はする() {
        let tree = [element("alert", "処理中", depth: 1)]
        XCTAssertEqual(ResidualSystemAlertTriage.describe(elements: tree), "処理中")
    }
}
