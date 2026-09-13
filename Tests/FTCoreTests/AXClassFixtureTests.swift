// 空打ちの第3段(AccessibilityClassHint)を、実際の XCUITest の木(Tests/Fixtures/AXClass/)に当てて
// フレームワークごとの答えを等号で固定する。値は XCTest の非公開属性 5004 由来なので、Xcode の版で
// 変わったらここが落ちる(README の手順で見直す)

import XCTest
@testable import FTCore

final class AXClassFixtureTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/AXClass")

    private func load(_ name: String) throws -> SnapshotResponse {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("xcui-\(name).json"))
        return try JSONDecoder().decode(SnapshotResponse.self, from: data)
    }

    /// button 型の要素のうち、第3段が「撃つ」と答える数 / 全数
    private func hostedButtons(_ name: String) throws -> (hosted: Int, total: Int) {
        let buttons = try load(name).elements.filter { $0.type == "button" }
        return (buttons.filter { AccessibilityClassHint.hostsOwnTouches($0) == true }.count, buttons.count)
    }

    func testComposeAndFlutterButtonsAreHosted() throws {
        for name in ["cmp", "flutter"] {
            let (hosted, total) = try hostedButtons(name)
            XCTAssertGreaterThan(total, 5, name)
            XCTAssertEqual(hosted, total, "\(name): 全ボタンが UIAccessibilityElement のはず")
        }
    }

    func testReactNativeSwiftUIAndUIKitButtonsAreNot() throws {
        for name in ["rn", "ios", "Preferences"] {
            let (hosted, total) = try hostedButtons(name)
            XCTAssertGreaterThan(total, 5, name)
            XCTAssertEqual(hosted, 0, "\(name): ビューを持つ要素なので撃たない")
        }
    }

    /// UIKit の実アプリにも UIAccessibilityElement は出る(地図の 6 件)。判定を「アプリ全体」でなく
    /// 掴んだ要素単位にしている理由の witness。**数を変えるなら中身を1件ずつ見てから**
    func testMapsHasAFewHostedElementsButNotItsButtons() throws {
        let elements = try load("Maps").elements
        XCTAssertEqual(elements.filter { AccessibilityClassHint.hostsOwnTouches($0) == true }.count, 6)
        let (hosted, total) = try hostedButtons("Maps")
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(hosted, 0)
    }

    /// 全要素が axClass を運ぶ(ランナーが根の走査で全ノードに付けている)
    func testEveryElementCarriesAClassName() throws {
        for name in ["cmp", "flutter", "rn", "ios", "Preferences", "Maps"] {
            let elements = try load(name).elements
            XCTAssertFalse(elements.isEmpty, name)
            XCTAssertTrue(elements.allSatisfy { !($0.axClass ?? "").isEmpty }, "\(name): axClass の欠けた要素がある")
        }
    }
}
