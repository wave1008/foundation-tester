import XCTest
@testable import FTCore

/// **入れ子のスクロール容器の中の行は、外側の容器の枠の外を覆えない**(Apple マップの乗換案内の手順画面・
/// Simulator・XCUITest で実際に取った木 = `Tests/Fixtures/OcclusionTrees/ios-maps_transit_tray_boarding_under_header.json`)。
/// シートを全開にして一覧を送ると、乗車案内のカード(内側の横スクロールの中)が見出しの「閉じる」の下へ潜る。
/// 外側の一覧(y=144 から下)がカードを切り取っているのに「覆っている」と誤報した(タップは閉じるに当たった)
final class NestedScrollerClippingOcclusionTests: XCTestCase {

    private func fixture() throws -> SnapshotResponse {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OcclusionTrees/ios-maps_transit_tray_boarding_under_header.json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: Data(contentsOf: url))
    }

    func testARowClippedByAnOuterScrollerDoesNotCoverTheHeaderButton() throws {
        let tree = try fixture()
        let close = try XCTUnwrap(tree.elements.first { $0.identifier == "TransitNavigationEndButton" })
        let over = OcclusionGeometry.overlayCovering(close, in: tree.elements, screen: tree.screen)
        XCTAssertNil(over, "外側の一覧に切り取られた行を「閉じる」を覆う相手と言った: \(over.map(TapTargetGeometry.describe) ?? "")")
    }

    /// **一覧の中で描かれている重なりは、今までどおり言う**(除外を広げすぎていない): 停車駅の行の詳細ボタンには
    /// 時刻のラベル(「4:58」)が中心に重なっている。どのスクロール容器もその点を含むので、除外の対象にならない
    func testOverlapsInsideEveryScrollerAreStillReported() throws {
        let tree = try fixture()
        let stopRowButton = try XCTUnwrap(tree.elements.first { element in
            element.identifier == "DetailButton" && tree.elements.contains {
                $0.label == "4:58" && TapTargetGeometry.contains(element.frame, FTRect(x: $0.frame.x + $0.frame.width / 2,
                                                                               y: $0.frame.y + $0.frame.height / 2,
                                                                               width: 0, height: 0))
            }
        })
        XCTAssertEqual(OcclusionGeometry.overlayCovering(stopRowButton, in: tree.elements, screen: tree.screen)?.label, "4:58")
    }
}
