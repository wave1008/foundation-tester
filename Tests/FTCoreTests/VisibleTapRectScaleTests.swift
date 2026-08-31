// 「見えている部分」を撃つ床(minimumVisibleTapExtent)を**木の単位へ換算**していること。
//
// 床は pt/dp で決めた物理量(約1.25mm)なのに、Android の木は px で来る。換算しないと
// 3倍密度の端末で床が約3倍緩くなり、**この guard が防ぐはずの誤タップ(容器の推測が
// 外れたときに、わずかな重なりを「見えている部分」と信じて叩く)が素通りする**。
// 失敗モードは沈黙(タップは 200 を返し、別の物が反応する)なので、緑は証拠にならない ——
// 「換算しなければ通ってしまう帯」を作り、**通らないこと**を見る。

import XCTest
@testable import FTCore

/// 固定の木を返し、tap が **ref と座標のどちらで来たか**だけ記録するドライバ
private final class TapRecordingDriver: AppDriver {
    private let elements: [ElementInfo]
    let pointScale: Double
    private(set) var refTaps: [Int] = []
    private(set) var coordinateTaps: [(Double, Double)] = []

    init(elements: [ElementInfo], pointScale: Double) {
        self.elements = elements
        self.pointScale = pointScale
    }

    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 300, height: 600),
                         elements: elements, truncatedCount: 0)
    }
    func tap(ref: Int) async throws { refTaps.append(ref) }
    func tap(x: Double, y: Double) async throws { coordinateTaps.append((x, y)) }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class VisibleTapRectScaleTests: XCTestCase {

    private func element(_ ref: Int, id: String, frame: FTRect,
                         type: String = "clickable") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: 1)
    }

    /// 容器(スクロール可能)の下端をまたぎ、**見えているのは 15 単位ぶんだけ**の行。
    /// 中心は容器の外に落ちるので visibleTapRect の対象になる
    /// 容器の推測(clippingContainer)は**同じ深さの兄弟が2つ以上**容器と交わることを要求するので、
    /// 完全に中に居る行を1つ添える
    private func straddling() -> [ElementInfo] {
        let container = element(1, id: "list", frame: FTRect(x: 0, y: 100, width: 300, height: 400),
                                type: "scrollable")
        var inside = element(2, id: "row_inside", frame: FTRect(x: 0, y: 110, width: 300, height: 100))
        inside.depth = 2
        // 容器は y=100..500。行は y=485..585(高さ100)= 見えているのは 15
        var row = element(3, id: "row", frame: FTRect(x: 0, y: 485, width: 300, height: 100))
        row.depth = 2
        return [container, inside, row]
    }

    /// pt の木(iOS)では 15pt 見えている = 床 8pt を超えるので寄せて撃つ
    func testASliverAbovePointFloorIsTappedOnAPointTree() {
        let elements = straddling()
        let visible = StepExecutor.visibleTapRect(for: elements[2], in: elements,
                                                  inferring: true, scale: 1)
        XCTAssertNotNil(visible, "15pt 見えているのに寄せなかった")
        XCTAssertEqual(visible?.height, 15)
    }

    /// **同じ木を px として受けた場合**(Android・密度3)は 15px = 5dp = 床 8dp 未満なので撃たない。
    /// ここが換算前は素通りしていた形(床 8 を px にそのまま当てると 15 >= 8 で通る)
    func testTheSameSliverIsRefusedOnAPixelTree() {
        let elements = straddling()
        XCTAssertNil(StepExecutor.visibleTapRect(for: elements[2], in: elements,
                                                 inferring: true, scale: 3),
                     "3倍密度では 15px = 5dp しか見えていない = 撃ってはいけない")
    }

    /// 逆方向: 換算しても**十分見えている**帯は従来どおり撃つ(床を上げただけの実装にしない)
    func testAWideEnoughVisibleBandIsStillTappedOnAPixelTree() {
        let container = element(1, id: "list", frame: FTRect(x: 0, y: 100, width: 300, height: 400),
                                type: "scrollable")
        var inside = element(2, id: "row_inside", frame: FTRect(x: 0, y: 110, width: 300, height: 100))
        inside.depth = 2
        // 見えているのは 40px = 13.3dp > 8dp
        var row = element(3, id: "row", frame: FTRect(x: 0, y: 460, width: 300, height: 100))
        row.depth = 2
        let elements = [container, inside, row]
        let visible = StepExecutor.visibleTapRect(for: row, in: elements, inferring: true, scale: 3)
        XCTAssertNotNil(visible, "40px = 13.3dp 見えているのに撃たなかった")
        XCTAssertEqual(visible?.height, 40)
    }

    // MARK: - 配線(StepExecutor が driver.pointScale を渡していること)

    /// **床の値だけ直しても、渡していなければ効かない**(既定 1 に落ちる)。
    /// 純粋関数のテストは規則の正しさしか見ないので、配線は実際の tap で確かめる:
    /// pt の木では「見えている部分」を**座標で**撃ち、px(密度3)の木では細すぎるので
    /// 従来どおり **ref で**撃つ
    func testTheExecutorFeedsTheDriverScaleIntoTheFloor() async {
        let pointTree = TapRecordingDriver(elements: straddling(), pointScale: 1)
        _ = await StepExecutor(driver: pointTree, isAndroid: false)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row")))
        XCTAssertEqual(pointTree.coordinateTaps.count, 1,
                       "pt の木で見えている部分へ寄せていない: \(pointTree.refTaps) / \(pointTree.coordinateTaps)")

        let pixelTree = TapRecordingDriver(elements: straddling(), pointScale: 3)
        _ = await StepExecutor(driver: pixelTree, isAndroid: false)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row")))
        XCTAssertTrue(pixelTree.coordinateTaps.isEmpty,
                      "3倍密度で 5dp しか見えていない帯を座標で撃った: \(pixelTree.coordinateTaps)")
        XCTAssertEqual(pixelTree.refTaps.count, 1)
    }

    /// 既定は 1(= 換算しない)。iOS 系ドライバの木は pt なので、既定が変わると
    /// **全 iOS 端末で床が動く**
    func testTheDefaultScaleIsOne() {
        XCTAssertEqual(StepExecutor.visibleTapRect(for: straddling()[2], in: straddling(),
                                                   inferring: true)?.height,
                       15, "既定の scale が 1 でなくなっている")
    }
}
