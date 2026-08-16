// 探索スワイプの刻みを詰める自己補正(`spanScale`)が、**容器の高さ**を基準に発火することを固定する。
//
// 旧実装は**画面の高さ**で割っていた。容器は定義上それより小さいので、実移動量が容器を大きく
// 超えていても閾値(0.8×画面)に届かず**ほぼ発火しなかった** —— docs/performance-tuning.md
// §3.18(f) の実測を当てると、SwiftUI は 1 スワイプ 681pt に対し閾値 699pt で素通りする一方、
// リストの可視高は 492pt = 1.38 倍の超過(いちばん取りこぼす SUT でガードが無効だった)。
//
// **効くのは `scrollFrame` を書いた経路だけ**(刻みを縮める口が `scrollPath` しかないため)。
// 未指定の経路はエンジン既定に委ねる = ここを広げると2度撤回した暗黙の座標化になる。

import XCTest
@testable import FTCore

/// `swipe(_:intent:path:)` を**素通しせず自分で受ける**ドライバ。既定実装に任せると
/// path が落ちて「刻みが縮んだか」を観測できない(AppDriver の既定は自分の swipe(_:) を呼ぶ)
private final class PathRecordingDriver: AppDriver {
    let elements: [[ElementInfo]]
    private(set) var snapshotCount = 0
    private(set) var paths: [FTSwipePath?] = []

    init(elements: [[ElementInfo]]) { self.elements = elements }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { paths.append(nil) }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        paths.append(path)
    }

    func snapshot() async throws -> SnapshotResponse {
        snapshotCount += 1
        let frame = elements[min(snapshotCount - 1, elements.count - 1)]
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: frame, truncatedCount: 0)
    }
}

final class ScrollSpanShrinkTests: XCTestCase {

    /// 容器 `#list_rows` は y 230..692(高さ 462)。閾値は 0.8×462 = 369.6pt。
    /// **画面基準だと 0.8×874 = 699.2pt** なので、下の 500pt の移動は旧実装では素通りする
    private static func frame(anchorY: Double) -> [ElementInfo] {
        [ElementInfo(ref: 1, type: "other", identifier: "list_rows", label: nil, value: nil,
                     placeholder: nil, enabled: true,
                     frame: FTRect(x: 16, y: 230, width: 370, height: 462), depth: 1),
         ElementInfo(ref: 2, type: "clickable", identifier: "anchor", label: "行", value: nil,
                     placeholder: nil, enabled: true,
                     frame: FTRect(x: 16, y: anchorY, width: 370, height: 56), depth: 2)]
    }

    /// 距離を測る。縦方向なので y の移動量(始点→終点)
    private func span(_ path: FTSwipePath?) -> Double {
        guard let path else { return 0 }
        return abs(path.toY - path.fromY)
    }

    /// **容器を 1.08 倍超えた移動を観測したら次の刻みが縮む**。
    /// 500pt(容器 462 の 1.08 倍)は旧実装の閾値 699.2pt には届かないので、
    /// 画面基準に戻すとこのテストは落ちる。
    ///
    /// **フレーム列は探索ループの取得順に合わせる**: 1周目は `settledSignature` が
    /// 「連続2回同じ」を確認するので**同じ木を2枚**消費し、2周目の1枚が移動後になる
    func testSpanShrinksWhenTravelExceedsTheContainer() async throws {
        // 整定(600・600)→ 探索2周目に y=100 = 500pt 動いた
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 600),
                                                    Self.frame(anchorY: 600),
                                                    Self.frame(anchorY: 100)])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"),
                            direction: "up", maxSwipes: 2,
                            scrollFrame: FlowLocator(id: "list_rows"))

        _ = await StepExecutor(driver: driver).execute(step)

        let swipes = driver.paths.compactMap { $0 }
        XCTAssertGreaterThanOrEqual(swipes.count, 2, "刻みの比較には2回ぶんの path が要る: \(driver.paths)")
        XCTAssertLessThan(span(swipes[1]), span(swipes[0]) * 0.95,
                          "容器を超える移動を観測したのに刻みが縮んでいない"
                          + "(1周目 \(span(swipes[0]))pt → 2周目 \(span(swipes[1]))pt)")
    }

    /// 容器に収まる移動では縮めない(縮めるほどスワイプ本数が増えて遅くなるので、
    /// **必要なときだけ**発火させる)
    func testSpanIsKeptWhenTravelFitsInTheContainer() async throws {
        // 整定(400・400)→ 探索2周目に y=300(= 100pt。閾値 369.6pt を下回る)
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 400),
                                                    Self.frame(anchorY: 400),
                                                    Self.frame(anchorY: 300)])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"),
                            direction: "up", maxSwipes: 2,
                            scrollFrame: FlowLocator(id: "list_rows"))

        _ = await StepExecutor(driver: driver).execute(step)

        let swipes = driver.paths.compactMap { $0 }
        XCTAssertGreaterThanOrEqual(swipes.count, 2)
        XCTAssertEqual(span(swipes[1]), span(swipes[0]), accuracy: 0.001,
                       "容器に収まっているのに刻みを縮めてはいけない")
    }

    /// **`scrollFrame` 未指定なら path を送らない**(= エンジン既定の刻みに委ねる)。
    /// ここが nil でなくなったら、2度撤回した「暗黙の座標化」が復活している
    func testUnspecifiedScrollFrameSendsNoPath() async throws {
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 600),
                                                    Self.frame(anchorY: 100)])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"),
                            direction: "up", maxSwipes: 2)

        _ = await StepExecutor(driver: driver).execute(step)

        XCTAssertFalse(driver.paths.isEmpty, "スワイプ自体は撃たれるはず")
        XCTAssertTrue(driver.paths.allSatisfy { $0 == nil },
                      "領域未指定で座標を送ってはいけない(暗黙の座標化は2度撤回済み): \(driver.paths)")
    }
}
