import XCTest
@testable import FTCore

/// 自動許可が「どれを押すか」。**押し間違いは沈黙の事故**(意図しない権限で run が緑のまま進む)
/// なので、部分一致・型の緩みは入れない
final class SystemAlertDismissalTests: XCTestCase {

    private func button(_ label: String, type: String = "button",
                        enabled: Bool = true) -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
    }

    func test並べた順で先に見つかったものを採る() {
        let tree = [button("許可しない"), button("Appの使用中は許可"), button("1回だけ許可")]
        let hit = SystemAlertDismissal.buttonToTap(
            in: tree, labels: ["Appの使用中は許可", "1回だけ許可"])
        XCTAssertEqual(hit?.label, "Appの使用中は許可")
    }

    func test前のラベルが無ければ次のラベルへ落ちる() {
        let tree = [button("許可しない"), button("1回だけ許可")]
        let hit = SystemAlertDismissal.buttonToTap(
            in: tree, labels: ["Appの使用中は許可", "1回だけ許可"])
        XCTAssertEqual(hit?.label, "1回だけ許可")
    }

    /// **これが最重要**: 部分一致にすると "許可" の指定で "許可しない" を押してしまう
    func test部分一致では押さない() {
        let tree = [button("許可しない")]
        XCTAssertNil(SystemAlertDismissal.buttonToTap(in: tree, labels: ["許可"]))
    }

    func test前後の空白は落として比較する() {
        let tree = [button("Allow")]
        XCTAssertEqual(SystemAlertDismissal.buttonToTap(in: tree, labels: ["  Allow  "])?.label,
                       "Allow")
    }

    /// 一覧が空 = 機能オフ。何があっても押さない
    func testラベル未指定なら何も押さない() {
        let tree = [button("許可"), button("OK")]
        XCTAssertNil(SystemAlertDismissal.buttonToTap(in: tree, labels: []))
        XCTAssertNil(SystemAlertDismissal.buttonToTap(in: tree, labels: ["   "]))
    }

    /// ボタン以外は押さない(同じ文言の見出し・説明文を叩かない)
    func testボタン以外の型は押さない() {
        let tree = [button("許可", type: "staticText")]
        XCTAssertNil(SystemAlertDismissal.buttonToTap(in: tree, labels: ["許可"]))
    }

    func test無効なボタンは押さない() {
        let tree = [button("許可", enabled: false)]
        XCTAssertNil(SystemAlertDismissal.buttonToTap(in: tree, labels: ["許可"]))
    }

    /// 押した記録は**何を押したか**まで出す。出さないと、無関係のアプリのアラートを
    /// 押していても後から気付けない(受け手報告: マップのアラートが対象アプリの前面に出た)
    func test押した記録はアラートの題とボタン名を両方出す() {
        let tree = [
            ElementInfo(ref: 1, type: "alert", identifier: nil,
                        label: "“マップ”に位置情報の使用を許可しますか?", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1),
            button("アプリの使用中は許可"),
        ]
        let described = SystemAlertDismissal.actionDescription(pressed: tree[1], in: tree)
        XCTAssertTrue(described.contains("アプリの使用中は許可"), described)
        XCTAssertTrue(described.contains("“マップ”"), "どのアラートを押したかが要る: \(described)")
        XCTAssertTrue(described.contains("systemAlertHandler"),
                      "誰が押したのか(設定由来)も出すこと: \(described)")
    }

    /// 題の無いアラートでも「押した」ことは残す(題が無いから黙る、にしない)
    func test題が無くても押したことは残す() {
        let target = button("OK")
        let described = SystemAlertDismissal.actionDescription(pressed: target, in: [target])
        XCTAssertTrue(described.contains("OK"), described)
        XCTAssertTrue(described.contains("systemAlertHandler"), described)
    }

    func test一覧に無いラベルのボタンは押さない() {
        let tree = [button("あとで")]
        XCTAssertNil(SystemAlertDismissal.buttonToTap(in: tree, labels: ["許可", "OK"]))
    }
}
