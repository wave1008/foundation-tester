// 対象領域が決まったピンチの、指2本の置き方(純粋関数)。**OS ごとに規則が違う**
// (座標ジェスチャの表現力そのものが OS で違うため、意図して統一しない。詳細は各関数の doc)。
//
// **ブリッジは指を置かない** —— ここが返す粗いキーフレーム(`GestureFinger`)を `PinchRequest.fingers` で
// 受け取り再生するだけ(点の間の補間は各ブリッジの `/gesture` と同じ再生器)。
//
// `PinchRegion.closingTouchPoints` は「対象未指定のピンチをどこへ当てるか」(ホスト側の領域探索)の
// ための2点で、ここの `ios(frame:...)` が実際に置く指(0.8 内側)より外側にある —— 両者は別の関数
// だが**同じ向き・端の規則**を共有する(片方だけ変えない)。

import Foundation

public enum PinchGesture {

    /// scale が不正(0 以下・1・非有限)なときに投げる
    public struct InvalidScale: Error, Equatable, Sendable {
        public let scale: Double
    }

    // MARK: - iOS(座標ピンチ。XCUITest ランナー・in-app 共通)

    /// 押してから動き出す / 止まってから離すまでに置く保持(所要に対する割合)。
    /// 押下と最初の移動が同時刻だと
    /// recognizer が開始を取りこぼすことがある
    private static let iosHoldRatio = 0.2

    /// 指を枠の縁ちょうどには置かない内側寄せ。境界の座標は隣の要素に拾われうる。
    /// Android の 0.9 より一段内側 —— iOS は枠が画面いっぱいのことがあり、画面の縁は
    /// システムジェスチャ帯になる
    private static let iosEdgeInset = 0.8

    /// 閉じ切った側でも指をこれ以上近づけない半径の床[pt](Android の 16px 床と同じ考え)。
    /// 指が重なるまで閉じると、ピンチではなく1本指の操作として届く
    private static let iosMinimumHalfSpan = 8.0

    /// よほど縦長(長辺が短辺の2倍超)の枠のときだけ指を縦に並べる。原則は横 ——
    /// 縦に並べると同時に効いている縦スクロールの recognizer に指を取られる。
    /// **`PinchRegion.closingTouchPoints` と同じ閾値**(片方だけ変えない)
    private static let iosVerticalAspectThreshold = 2.0

    /// `frame` の中で向かい合う2本指の経路を作る。縮小(`scale < 1`)は外側→内側、拡大は
    /// 内側→外側。指は `frame` の外へ出ない。返すのは粗いキーフレーム(押す・保持後の到達点・
    /// 保持前の出発点・離す)で、**区間の割り方はランナー側**(`CoordinatePinch.resample`。`/gesture` と共有)
    public static func ios(frame: FTRect, scale: Double, durationSeconds: Double) throws -> [GestureFinger] {
        guard scale.isFinite, scale > 0, scale != 1 else { throw InvalidScale(scale: scale) }
        let vertical = frame.height > frame.width * iosVerticalAspectThreshold
        let centreX = frame.x + frame.width / 2
        let centreY = frame.y + frame.height / 2
        let outerHalf = (vertical ? frame.height : frame.width) / 2 * iosEdgeInset
        let innerHalf = max(outerHalf * min(scale, 1 / scale), iosMinimumHalfSpan)
        func points(_ halfSpan: Double) -> [(x: Double, y: Double)] {
            vertical
                ? [(centreX, centreY - halfSpan), (centreX, centreY + halfSpan)]
                : [(centreX - halfSpan, centreY), (centreX + halfSpan, centreY)]
        }
        let zoomingOut = scale < 1
        let starts = points(zoomingOut ? outerHalf : innerHalf)
        let ends = points(zoomingOut ? innerHalf : outerHalf)
        let hold = durationSeconds * iosHoldRatio
        return zip(starts, ends).map { start, end in
            GestureFinger(points: [
                GesturePoint(x: start.x, y: start.y, t: 0),
                GesturePoint(x: start.x, y: start.y, t: hold),
                GesturePoint(x: end.x, y: end.y, t: durationSeconds - hold),
                GesturePoint(x: end.x, y: end.y, t: durationSeconds),
            ])
        }
    }

    // MARK: - Android(apk 経由)

    /// 指2本をこれ以上近づけない距離の床[px](タッチスロップ。Java の `16`)
    private static let androidMinimumSpan = 16.0

    /// 短辺に対するピンチの最大スパン比。**倍率が正確に出る側(広い方)を先に決める** ——
    /// 先に狭い方を決めて scale 倍すると領域からはみ出し、クランプで倍率が黙って目減りする
    private static let androidMaxSpanRatio = 0.9

    /// 45度の対角線に指を置く(水平/垂直だとその向きのスクロールと競合しやすい)。
    /// 各軸への射影は `span/2 * cos45`
    private static let androidDiagonalAxis = 0.5.squareRoot()

    /// `frame` の中心で開閉する2本指の経路を作る(呼び手は対象未指定なら画面全体の frame を渡す ——
    /// Android は領域の短辺から指の幅を決めるので nil を許さない)
    public static func android(frame: FTRect, scale: Double, durationSeconds: Double) throws -> [GestureFinger] {
        guard scale.isFinite, scale > 0, scale != 1 else { throw InvalidScale(scale: scale) }
        let centreX = frame.x + frame.width / 2
        let centreY = frame.y + frame.height / 2
        let maxSpan = min(frame.width, frame.height) * androidMaxSpanRatio
        let startSpan: Double
        let endSpan: Double
        if scale > 1 {
            endSpan = maxSpan
            startSpan = max(maxSpan / scale, androidMinimumSpan)
        } else {
            startSpan = maxSpan
            endSpan = max(maxSpan * scale, androidMinimumSpan)
        }
        // Java の `Math.min(Math.max(seconds*1000, 50), 60000)` と同じ床/天井
        // (60s = BridgeAPI.gestureSecondsCeiling。ここが最後の砦ではない値の写しなので定数を共有する)
        let clampedDuration = min(max(durationSeconds, 0.05), BridgeAPI.gestureSecondsCeiling)
        func points(_ span: Double) -> [(x: Double, y: Double)] {
            let offset = span / 2 * androidDiagonalAxis
            return [(centreX - offset, centreY - offset), (centreX + offset, centreY + offset)]
        }
        let starts = points(startSpan)
        let ends = points(endSpan)
        return zip(starts, ends).map { start, end in
            GestureFinger(points: [
                GesturePoint(x: start.x, y: start.y, t: 0),
                GesturePoint(x: end.x, y: end.y, t: clampedDuration),
            ])
        }
    }
}
