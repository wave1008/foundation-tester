// 対象未指定のピンチを当てる領域の判定。
// **根拠はデバイスでの実測**(2026-09-22・Apple マップ / iPhone 17 Pro iOS 27.0):
// 指の2点が別々のものに載ると、ピンチにならず片方に持っていかれてパンになる。

import XCTest
@testable import FTCore

final class PinchRegionTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                         identifier: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: identifier, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
    }

    /// 邪魔が無ければ**既定の半径で横向き**に置く(縦長の画面では上下に帯が載りやすいので横が先)
    func testPlacesTheFingersHorizontallyWhenNothingIsInTheWay() throws {
        let content = element(1, 0, 0, 402, 874)
        let area = try XCTUnwrap(PinchRegion.area(elements: [content], screen: screen))
        let radius = 402 * PinchRegion.radiusFractions[0]
        XCTAssertGreaterThan(area.width, area.height, "横向きに置くこと")
        XCTAssertEqual(area.width, radius * 2, accuracy: 0.001)
        XCTAssertEqual(area.x + area.width / 2, 201, accuracy: 0.001)
        XCTAssertEqual(area.y + area.height / 2, 437, accuracy: 0.001)
    }

    /// **実害そのもの**: 下から出ているシートに指の片方が載ると、地図から見て指1本 = パンになる。
    /// 横向きなら両方とも地図に載るので、そちらが選ばれること
    func testKeepsBothFingersOffASheetThatComesUpFromTheBottom() throws {
        let map = element(1, 0, 0, 402, 500)
        let sheet = element(2, 0, 480, 402, 394)          // 中央(437)より下に食い込む
        let area = try XCTUnwrap(PinchRegion.area(elements: [map, sheet], screen: screen))
        for point in PinchRegion.closingTouchPoints(in: area) {
            XCTAssertLessThan(point.y, 480, "指がシートに載っている: \(point)")
        }
    }

    /// 左右が塞がれていたら**半径を狭める**(諦める前に近づける)。
    /// 覆いは**容器からはみ出す**形にする —— 容器に収まる要素は中身(ピン・ラベル)なので同じ面
    func testNarrowsTheSpanBeforeGivingUp() throws {
        let map = element(1, 20, 100, 362, 600)
        // 覆いはどれも容器からはみ出す = 別の面。既定の半径では縦も横も置けない
        let left = element(2, 0, 0, 150, 874)
        let right = element(3, 252, 0, 150, 874)
        let top = element(4, 0, 0, 402, 360)
        let bottom = element(5, 0, 500, 402, 374)
        let area = try XCTUnwrap(
            PinchRegion.area(elements: [map, left, right, top, bottom], screen: screen))
        let widest = 402 * PinchRegion.radiusFractions[0] * 2
        XCTAssertLessThan(max(area.width, area.height), widest, "半径を狭めること")
        for point in PinchRegion.closingTouchPoints(in: area) {
            XCTAssertTrue(point.x > 150 && point.x < 252, "覆いに載っている: \(point)")
        }
    }

    /// 判定材料が無ければ nil(呼び手は従来どおり画面全体で撃つ)
    func testGivesUpWithoutAnythingUnderTheCentre() {
        XCTAssertNil(PinchRegion.area(elements: [], screen: screen))
        XCTAssertNil(PinchRegion.area(elements: [element(1, 0, 0, 402, 100)], screen: screen),
                     "中央に何も無ければ置かない")
        XCTAssertNil(PinchRegion.area(elements: [element(1, 0, 0, 402, 874)],
                                      screen: FTRect(x: 0, y: 0, width: 0, height: 0)))
    }

    /// **入れ子は「同じもの」** —— 地図の上のピンで弾くと、実際には同じ地図なのに置けなくなる。
    /// **既定の置き方が変わらないこと**まで見る(弾くと縦や狭い半径へ逃げてしまう)
    func testTreatsNestedElementsAsTheSameContent() throws {
        let map = element(1, 0, 0, 402, 874)
        let radius = 402 * PinchRegion.radiusFractions[0]
        // 既定の左の指(201 - radius, 437)にちょうど載る小さなピン
        let pin = element(2, 201 - radius - 10, 427, 30, 30)
        let plain = try XCTUnwrap(PinchRegion.area(elements: [map], screen: screen))
        let withPin = try XCTUnwrap(PinchRegion.area(elements: [map, pin], screen: screen))
        XCTAssertEqual(withPin.x, plain.x, accuracy: 0.001, "ピンで置き方を変えないこと")
        XCTAssertEqual(withPin.y, plain.y, accuracy: 0.001)
        XCTAssertEqual(withPin.width, plain.width, accuracy: 0.001)
    }

    /// 端の取り方は**ブリッジと同じ規則**。片方だけ変えると指の位置が食い違う。
    /// **原則は横並び** —— 縦に並べると縦スクロールの recognizer が指を取る(実測)
    func testTouchPointsGoSidewaysUnlessTheFrameIsVeryTall() {
        let wide = PinchRegion.closingTouchPoints(in: FTRect(x: 10, y: 100, width: 200, height: 50))
        XCTAssertEqual(wide.map(\.x), [10, 210])
        XCTAssertEqual(wide.map(\.y), [125, 125])
        // 縦長でも 2 倍までは横に並べる(SUT の #pad_map は 402x622 = 1.55 倍)
        let tallish = PinchRegion.closingTouchPoints(in: FTRect(x: 0, y: 156, width: 402, height: 622))
        XCTAssertEqual(tallish.map(\.y), [467, 467])
        XCTAssertEqual(tallish.map(\.x), [0, 402])
        // 2 倍を超えたら縦
        let tall = PinchRegion.closingTouchPoints(in: FTRect(x: 10, y: 100, width: 50, height: 200))
        XCTAssertEqual(tall.map(\.x), [35, 35])
        XCTAssertEqual(tall.map(\.y), [100, 300])
    }
}

/// **3つの呼び手が全部この判定を通ること**をソース走査で固定する。型では守れない ——
/// どの呼び手も frame を nil のまま渡す形に戻せてしまい、そのときデバイス上でしか差が出ない
/// (縮小が黙ってパンになる)。
extension PinchRegionTests {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// **Android には渡さない** —— あちらは領域の短辺から指の幅を決めて中心に置くので、
    /// 狭い領域だと最小スケール幅(27mm)に届かずズームにならない
    /// (実測 2026-09-22: E2E の対象未指定 pinchOut が `zoom=-` になった)
    func testTheAreaIsNotUsedOnAndroid() throws {
        let dsl = try source("Sources/FTCore/StepExecutor+Actions.swift")
        let call = try XCTUnwrap(dsl.range(of: "PinchRegion.area(elements: snapshot.elements,"))
        XCTAssertTrue(String(dsl[..<call.lowerBound].suffix(160)).contains("!isAndroid"),
                      "Android では領域を渡さないこと")
        let live = try source("Sources/fleetest/ApiLiveCommand.swift")
        let liveCall = try XCTUnwrap(live.range(of: "PinchRegion.area(elements: snapshot.elements,"))
        XCTAssertTrue(String(live[..<liveCall.lowerBound].suffix(160)).contains("== \"ios\""),
                      "ライブ操作も iOS のときだけ渡すこと")
        let mcp = try source("Sources/fleetest-mcp/MCPServer+GesturesTools.swift")
        let mcpCall = try XCTUnwrap(mcp.range(of: "PinchRegion.area(elements: snapshot.elements,"))
        XCTAssertTrue(String(mcp[..<mcpCall.lowerBound].suffix(420)).contains("AndroidDriver"),
                      "MCP も Android を外すこと")
    }

    func testEveryPinchCallerAsksForTheArea() throws {
        for path in ["Sources/FTCore/StepExecutor+Actions.swift",
                     "Sources/fleetest/ApiLiveCommand.swift",
                     "Sources/fleetest-mcp/MCPServer+GesturesTools.swift"] {
            XCTAssertTrue(try source(path).contains("PinchRegion.area("),
                          "\(path) が対象未指定のピンチで PinchRegion を通っていない")
        }
    }

    /// 指の置き方は `PinchGesture.ios` の1箇所(ホスト)。**向きの規則が `closingTouchPoints` と同じ**で、
    /// 指は外側の2点の内側に収まる(= 外側で「同じものに載る」を確かめれば実際の指も同じものの上)
    func testPinchGestureUsesTheSameAxisAndStaysInsideTheClosingPoints() throws {
        for frame in [FTRect(x: 0, y: 0, width: 400, height: 300),
                      FTRect(x: 10, y: 20, width: 100, height: 400),
                      FTRect(x: 0, y: 0, width: 100, height: 200)] {
            let ends = PinchRegion.closingTouchPoints(in: frame)
            let axisIsVertical = ends[0].x == ends[1].x
            for scale in [2.0, 0.5] {
                let fingers = try PinchGesture.ios(frame: frame, scale: scale, durationSeconds: 0.5)
                for point in fingers.flatMap(\.points) {
                    if axisIsVertical {
                        XCTAssertEqual(point.x, ends[0].x, accuracy: 0.001, "\(frame) の指は縦に並ぶ")
                        XCTAssertTrue(point.y >= ends[0].y && point.y <= ends[1].y, "\(frame) \(point)")
                    } else {
                        XCTAssertEqual(point.y, ends[0].y, accuracy: 0.001, "\(frame) の指は横に並ぶ")
                        XCTAssertTrue(point.x >= ends[0].x && point.x <= ends[1].x, "\(frame) \(point)")
                    }
                }
            }
        }
    }

    /// ランナーは指を置かない(ホストの経路を再生するだけ)。座標ピンチが非公開 API なので、
    /// **存在確認と縮退**は残す
    func testTheRunnerReplaysHostFingersAndDegradesSafely() throws {
        let runner = try source("Runner/FleetestRunnerUITests/BridgeRouter.swift")
        XCTAssertTrue(runner.contains("CoordinatePinch.isAvailable"),
                      "非公開 API の存在を確かめてから使うこと")
        XCTAssertFalse(runner.contains("frame.height > frame.width"),
                       "ランナーに指の置き方の規則を戻さない(PinchGesture.ios が唯一の定義元)")
        XCTAssertTrue(runner.contains("no coordinate pinch in this Xcode"),
                      "縮退したことを注記で言うこと")
    }
}
