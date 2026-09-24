// PinchGesture.ios / .android の指の置き方(純粋関数)を、旧ブリッジ側実装
// (Runner の CoordinatePinch.pinch / AndroidRunner の InputInjector.pinch)と同じ数値になることで
// 固定する。ここは移植の等価性を確かめるテストなので、**ドキュメント化された規則そのもの**
// (edgeInset 0.8・8pt 床・maxSpanRatio 0.9・16px 床・45度)を式として書く —— PinchGesture の
// private 定数は参照できない(意図的にテストから見えない)ので、二重に書いても「同じ定数を
// 書き写しただけ」にはならない。

import XCTest
@testable import FTCore

final class PinchGestureTests: XCTestCase {

    // MARK: - iOS

    func testIOSHorizontalZoomIn() throws {
        let frame = FTRect(x: 0, y: 0, width: 400, height: 300)
        let fingers = try PinchGesture.ios(frame: frame, scale: 2, durationSeconds: 0.5)
        XCTAssertEqual(fingers.count, 2)
        // horizontal (height 300 <= width 400 * 2). outerHalf = 400/2*0.8 = 160.
        // innerHalf = max(160 * min(2, 0.5), 8) = 80. zoom in: inner → outer.
        let expected = [
            GestureFinger(points: [
                GesturePoint(x: 120, y: 150, t: 0),
                GesturePoint(x: 120, y: 150, t: 0.1),
                GesturePoint(x: 40, y: 150, t: 0.4),
                GesturePoint(x: 40, y: 150, t: 0.5),
            ]),
            GestureFinger(points: [
                GesturePoint(x: 280, y: 150, t: 0),
                GesturePoint(x: 280, y: 150, t: 0.1),
                GesturePoint(x: 360, y: 150, t: 0.4),
                GesturePoint(x: 360, y: 150, t: 0.5),
            ]),
        ]
        XCTAssertEqual(fingers, expected)
    }

    func testIOSHorizontalZoomOut() throws {
        let frame = FTRect(x: 0, y: 0, width: 400, height: 300)
        let fingers = try PinchGesture.ios(frame: frame, scale: 0.5, durationSeconds: 0.5)
        // zoom out: outer → inner (fingers converge)
        let expected = [
            GestureFinger(points: [
                GesturePoint(x: 40, y: 150, t: 0),
                GesturePoint(x: 40, y: 150, t: 0.1),
                GesturePoint(x: 120, y: 150, t: 0.4),
                GesturePoint(x: 120, y: 150, t: 0.5),
            ]),
            GestureFinger(points: [
                GesturePoint(x: 360, y: 150, t: 0),
                GesturePoint(x: 360, y: 150, t: 0.1),
                GesturePoint(x: 280, y: 150, t: 0.4),
                GesturePoint(x: 280, y: 150, t: 0.5),
            ]),
        ]
        XCTAssertEqual(fingers, expected)
    }

    /// 縦長(高さ > 幅 * 2)の枠は指を縦に並べる
    func testIOSVerticalFrameStacksFingersVertically() throws {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 400)
        let fingers = try PinchGesture.ios(frame: frame, scale: 2, durationSeconds: 0.5)
        // vertical (400 > 100*2). outerHalf = 400/2*0.8 = 160. innerHalf = max(160*0.5, 8) = 80.
        let expected = [
            GestureFinger(points: [
                GesturePoint(x: 50, y: 120, t: 0),
                GesturePoint(x: 50, y: 120, t: 0.1),
                GesturePoint(x: 50, y: 40, t: 0.4),
                GesturePoint(x: 50, y: 40, t: 0.5),
            ]),
            GestureFinger(points: [
                GesturePoint(x: 50, y: 280, t: 0),
                GesturePoint(x: 50, y: 280, t: 0.1),
                GesturePoint(x: 50, y: 360, t: 0.4),
                GesturePoint(x: 50, y: 360, t: 0.5),
            ]),
        ]
        XCTAssertEqual(fingers, expected)
    }

    /// 極端な scale では指が重ならないよう 8pt の床で止まる(0.4pt まで閉じない)
    func testIOSMinimumHalfSpanFloorStopsFingersFromMeeting() throws {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 50)
        let fingers = try PinchGesture.ios(frame: frame, scale: 100, durationSeconds: 1.0)
        // horizontal. outerHalf = 100/2*0.8 = 40. innerHalf = max(40*0.01, 8) = 8 (floor, not 0.4).
        let expected = [
            GestureFinger(points: [
                GesturePoint(x: 42, y: 25, t: 0),
                GesturePoint(x: 42, y: 25, t: 0.2),
                GesturePoint(x: 10, y: 25, t: 0.8),
                GesturePoint(x: 10, y: 25, t: 1.0),
            ]),
            GestureFinger(points: [
                GesturePoint(x: 58, y: 25, t: 0),
                GesturePoint(x: 58, y: 25, t: 0.2),
                GesturePoint(x: 90, y: 25, t: 0.8),
                GesturePoint(x: 90, y: 25, t: 1.0),
            ]),
        ]
        XCTAssertEqual(fingers, expected)
    }

    func testIOSInvalidScaleThrows() {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 100)
        for scale in [0.0, 1.0, -1.0] {
            XCTAssertThrowsError(try PinchGesture.ios(frame: frame, scale: scale, durationSeconds: 0.5)) {
                XCTAssertEqual($0 as? PinchGesture.InvalidScale, PinchGesture.InvalidScale(scale: scale))
            }
        }
        // NaN は NaN 同士でも == が false になる(IEEE 754)ので、投げること自体だけを確かめる
        for scale in [Double.nan, Double.infinity] {
            XCTAssertThrowsError(try PinchGesture.ios(frame: frame, scale: scale, durationSeconds: 0.5))
        }
    }

    // MARK: - Android

    /// **maxSpan は production の私有定数(0.9・16px 床)へアクセスできないので、ここで doc の式を
    /// 独立に再現する**(`min(width,height) * 0.9` は 100*0.9 のような単純な倍数でも二進浮動小数点で
    /// 割り切れるとは限らないため、`45.0`/`90.0` のような書き起こしの丸めズレを避け、同じ式を
    /// 同じ順序で評価してビット一致させる)
    private func androidMaxSpan(_ frame: FTRect) -> Double { min(frame.width, frame.height) * 0.9 }
    private let androidTouchSlopFloor = 16.0
    private let androidAxis = 0.5.squareRoot()

    func testAndroidSpanScaleUpWithoutFloor() throws {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 200)
        let fingers = try PinchGesture.android(frame: frame, scale: 2, durationSeconds: 1.0)
        XCTAssertEqual(fingers.count, 2)
        // scale > 1: endSpan = maxSpan, startSpan = max(maxSpan/scale, 16) — no floor here (45 > 16)
        let maxSpan = androidMaxSpan(frame)
        let startOffset = max(maxSpan / 2, 16) / 2 * androidAxis
        let endOffset = maxSpan / 2 * androidAxis
        let expected = [
            GestureFinger(points: [
                GesturePoint(x: 50 - startOffset, y: 100 - startOffset, t: 0),
                GesturePoint(x: 50 - endOffset, y: 100 - endOffset, t: 1.0),
            ]),
            GestureFinger(points: [
                GesturePoint(x: 50 + startOffset, y: 100 + startOffset, t: 0),
                GesturePoint(x: 50 + endOffset, y: 100 + endOffset, t: 1.0),
            ]),
        ]
        XCTAssertEqual(fingers, expected)
    }

    /// 極端な scale では 16px の床(タッチスロップ)で span が止まる
    func testAndroidSpanFloorsAtSixteenPixels() throws {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 200)
        let fingers = try PinchGesture.android(frame: frame, scale: 10, durationSeconds: 1.0)
        // maxSpan/scale (= maxSpan/10) is well under 16, so startSpan floors at 16
        let startOffset = androidTouchSlopFloor / 2 * androidAxis
        XCTAssertEqual(fingers[0].points.first?.x, 50 - startOffset)
        XCTAssertEqual(fingers[0].points.first?.y, 100 - startOffset)
    }

    /// scale < 1(縮小)は始点が maxSpan・終点が縮む側
    func testAndroidSpanScaleDown() throws {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 200)
        let fingers = try PinchGesture.android(frame: frame, scale: 0.5, durationSeconds: 1.0)
        let maxSpan = androidMaxSpan(frame)
        let startOffset = maxSpan / 2 * androidAxis
        let endOffset = max(maxSpan * 0.5, androidTouchSlopFloor) / 2 * androidAxis
        XCTAssertEqual(fingers[0].points.first?.x, 50 - startOffset)
        XCTAssertEqual(fingers[0].points.last?.x, 50 - endOffset)
    }

    func testAndroidDurationClampsToFiftyMillisecondsFloor() throws {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 200)
        let fingers = try PinchGesture.android(frame: frame, scale: 2, durationSeconds: 0.01)
        XCTAssertEqual(fingers[0].points.last?.t, 0.05)
    }

    /// 60 は文書化された値(`BridgeAPI.gestureSecondsCeiling`)をリテラルで書く ——
    /// 定数を読んで期待値にすると、定数そのものが動いたときにテストが検出できなくなる
    func testAndroidDurationClampsToTheSecondsCeiling() throws {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 200)
        let fingers = try PinchGesture.android(frame: frame, scale: 2, durationSeconds: 999)
        XCTAssertEqual(fingers[0].points.last?.t, 60.0)
    }

    func testAndroidInvalidScaleThrows() {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 200)
        for scale in [0.0, 1.0, -1.0] {
            XCTAssertThrowsError(try PinchGesture.android(frame: frame, scale: scale, durationSeconds: 1)) {
                XCTAssertEqual($0 as? PinchGesture.InvalidScale, PinchGesture.InvalidScale(scale: scale))
            }
        }
        for scale in [Double.nan, Double.infinity] {
            XCTAssertThrowsError(try PinchGesture.android(frame: frame, scale: scale, durationSeconds: 1))
        }
    }
}
