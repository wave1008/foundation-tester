// 座標を指定する多点ジェスチャ(2本指ピンチ / 指ごとの時刻つき経路の gesture)。**XCTest の公開 API には
// ピンチが `XCUIElement` にしか生えておらず**(iOS 27 の SDK を確認)、指の位置は要素の枠から決まる ——
// しかも**縮小は枠の長辺の両端から閉じる**ので、端に別のものが載っていると1本を取られ、ジェスチャが
// パンに化ける(実測 2026-09-22・Apple マップ: 地図の容器の下端が検索カードに接しており、縮小が必ず
// パンになった。公開 API の代替も無い —— 2本指タップは無反応・ダブルタップは拡大しかできない)。
// 座標指定の多点タッチジェスチャそのものにも公開 API が無い(`XCUICoordinate` は単点のみ)。
//
// そこで **Appium/WebDriverAgent と同じ非公開 API** で多点の経路を自分で組む。
// クラスは `XCPointerEventPath` / `XCSynthesizedEventRecord`(**`XCUI` 接頭辞は付かない**。
// 公開ヘッダには宣言が無い)。
//
// **非公開なので必ず実行時に確かめてから使う** —— Xcode の更新で消えうる(同じ調査で
// `XCTRunnerDaemonSession` が Xcode 27 の XCUIAutomation に無いことを確認した)。
// 無ければ `isAvailable == false` を返し、pinch の呼び手は公開 API の経路へ縮退する
// (gesture には縮退先が無いので BridgeRouter.handleGesture が 422 で断る)。
// 消えたことは `/status` の `coordinatePinch` で見える(ホストと doctor が読む)。

import Foundation
import UIKit
import XCTest

/// `XCPointerEventPath`(1本の指の経路)
@objc private protocol PointerEventPathSPI: NSObjectProtocol {
    @objc(initForTouchAtPoint:offset:) init(touchAt point: CGPoint, offset: Double)
    @objc(moveToPoint:atOffset:) func move(to point: CGPoint, atOffset offset: Double)
    @objc(liftUpAtOffset:) func liftUp(atOffset offset: Double)
}

/// `XCSynthesizedEventRecord`(複数の指をまとめた1つのイベント)
@objc private protocol SynthesizedEventRecordSPI: NSObjectProtocol {
    @objc(initWithName:interfaceOrientation:) init(name: String, interfaceOrientation: Int)
    @objc(addPointerEventPath:) func add(_ path: AnyObject)
}

/// イベントを実際に送る口。
/// **completion は引数を取らない形で受ける** —— 実際のブロックは先頭に BOOL を渡してくるので、
/// `(Error?) -> Void` で受けると Swift の thunk がその 1 を objc_retain して**落ちる**
/// (実測 2026-09-22: EXC_BAD_ACCESS at 0x1)。引数を宣言しなければ読まないので、
/// 向こうの型が変わっても壊れない。失敗は「絵が変わらない」として呼び手に現れる
@objc private protocol EventSynthesizerSPI: NSObjectProtocol {
    @objc(synthesizeEvent:completion:) func synthesize(_ record: AnyObject,
                                                       completion: @escaping @convention(block) () -> Void)
}

enum CoordinatePinch {

    /// pinch が指を動かす分割数。**1本の直線を数点に割る** —— 始点と終点だけだと速度が出ず、
    /// ピンチとして認識されないことがある(recognizer は移動量の履歴を見る)。
    /// pinch は所要が固定 0.05〜数秒の狭いレンジなので分割数を固定できるが、`gesture` は所要が
    /// 数十 ms 〜 `gestureSecondsCeiling`(60秒)まで伸びるので `stepInterval` の時間基準で刻む(下記)
    private static let steps = 12

    /// pinch が押してから動き出すまで / 止まってから離すまでに置く時間(所要に対する割合)
    private static let holdRatio = 0.2

    /// gesture のキーフレーム間(粗い move)を細かい move に割る間隔[秒]。60Hz はディスプレイの
    /// リフレッシュレート/タッチのサンプリング周期の目安で、これより細かく刻んでも recognizer に渡る
    /// 前に間引かれる。**静止区間(直前と同じ点)は分割しない** —— 位置が変わらないので終端の
    /// 1点で足りる(分割すると同一点への move を stepCount 回繰り返すだけで意味が無い)
    private static let stepInterval: TimeInterval = 1.0 / 60.0

    /// 連続する move に同じ offset を渡さないための最小間隔[秒]。**XCPointerEventPath が厳密な
    /// 単調増加を要求するかは非公開 API なので確認できない** —— キーフレームの間隔が
    /// `stepInterval` 未満(短い move・丸め)だと同一 offset の move が連続しうるので、常にこの床で
    /// 押し上げる。**最後の move → liftUp だけは同じ offset を許す**(pinch の従来の形がそう
    /// —— `move(to: to, atOffset: duration)` の直後に `liftUp(atOffset: duration)` — 動いていた実績と
    /// 同じ形なので、そこだけは踏襲する)
    private static let minimumOffsetStep: TimeInterval = 0.001

    /// この経路が使えるか(非公開 API の存在確認)。**呼ぶ前に必ず見る**
    static var isAvailable: Bool { classes != nil && synthesizer != nil }

    private static var classes: (path: PointerEventPathSPI.Type,
                                 record: SynthesizedEventRecordSPI.Type)? {
        guard let pathClass = NSClassFromString("XCPointerEventPath"),
              let recordClass = NSClassFromString("XCSynthesizedEventRecord"),
              pathClass.instancesRespond(to: Selector(("initForTouchAtPoint:offset:"))),
              pathClass.instancesRespond(to: Selector(("moveToPoint:atOffset:"))),
              pathClass.instancesRespond(to: Selector(("liftUpAtOffset:"))),
              recordClass.instancesRespond(to: Selector(("addPointerEventPath:")))
        else { return nil }
        return (unsafeBitCast(pathClass, to: PointerEventPathSPI.Type.self),
                unsafeBitCast(recordClass, to: SynthesizedEventRecordSPI.Type.self))
    }

    /// 送信口。**XCUIDevice の非公開プロパティ**から採る(WDA と同じ)。
    /// 見つからなければ nil = この経路は使えない
    private static var synthesizer: EventSynthesizerSPI? {
        let device = XCUIDevice.shared as NSObject
        guard device.responds(to: Selector(("eventSynthesizer"))),
              let raw = device.value(forKey: "eventSynthesizer") as? NSObject,
              raw.responds(to: Selector(("synthesizeEvent:completion:")))
        else { return nil }
        return unsafeBitCast(raw, to: EventSynthesizerSPI.self)
    }

    /// 2本の指を `from` の2点から `to` の2点へ同時に動かす。
    /// - Throws: 使えない / 送信が失敗したとき
    static func pinch(from start: (CGPoint, CGPoint), to end: (CGPoint, CGPoint),
                      duration: TimeInterval, orientation: UIInterfaceOrientation) throws {
        // **押した直後に動かさない・離す直前に止める** —— 押下と最初の移動が同じ時刻だと、
        // recognizer が開始を取りこぼすことがある(XCTest 自身のジェスチャも前後に間を置く)。
        // 保持は前後それぞれこの割合。**ここは自前のキーフレーム(完全展開)を組んで send() へ渡すだけ**
        // —— send() 側の時間分割は使わない(12 steps・holdRatio という固定の形を変えないため)
        let hold = duration * holdRatio
        let travel = duration - hold * 2
        // **for-in のタプルパターンで書く**(`.map { from, to in }` は SE-0110 以降のクロージャでは
        // 単一タプル引数への暗黙展開が効かず、型が合わない)
        var fingers: [[(point: CGPoint, offset: TimeInterval)]] = []
        for (from, to) in [(start.0, end.0), (start.1, end.1)] {
            var keyframes: [(point: CGPoint, offset: TimeInterval)] = [(from, 0), (from, hold)]
            for step in 1...steps {
                let ratio = Double(step) / Double(steps)
                keyframes.append((CGPoint(x: from.x + (to.x - from.x) * ratio,
                                          y: from.y + (to.y - from.y) * ratio),
                                  hold + travel * ratio))
            }
            keyframes.append((to, duration))
            fingers.append(keyframes)
        }
        try send(fingers: fingers, name: "fleetest pinch", orientation: orientation)
    }

    /// 指ごとの粗いキーフレーム(押す点→…→離す点。同じ点が続く区間 = 静止)を、認識されるだけの
    /// 密度に補間してから1つのタッチ列として再生する(gesture の実体)。
    /// - Parameter fingers: 各指のキーフレーム列。1本目の要素が touch down・最後が lift
    static func synthesize(fingers: [[(point: CGPoint, offset: TimeInterval)]], name: String,
                           orientation: UIInterfaceOrientation) throws {
        try send(fingers: fingers.map(subdivide), name: name, orientation: orientation)
    }

    /// 粗いキーフレームを `stepInterval` 刻みで補間する。静止区間(直前と同じ点)は補間しない
    private static func subdivide(_ keyframes: [(point: CGPoint, offset: TimeInterval)])
        -> [(point: CGPoint, offset: TimeInterval)] {
        guard let first = keyframes.first else { return [] }
        var out: [(point: CGPoint, offset: TimeInterval)] = [first]
        var previous = first
        for keyframe in keyframes.dropFirst() {
            if keyframe.point == previous.point {
                out.append(keyframe)
            } else {
                let span = keyframe.offset - previous.offset
                let stepCount = max(1, Int((span / stepInterval).rounded()))
                for step in 1...stepCount {
                    let ratio = Double(step) / Double(stepCount)
                    out.append((CGPoint(x: previous.point.x + (keyframe.point.x - previous.point.x) * ratio,
                                        y: previous.point.y + (keyframe.point.y - previous.point.y) * ratio),
                               previous.offset + span * ratio))
                }
            }
            previous = keyframe
        }
        return out
    }

    /// **SPI に触れる唯一の場所**(pinch と gesture が共有する)。フルに展開済みのキーフレームから
    /// 指1本につきパスを1本組み、全部を1つの record にまとめて送り、完了を待つ
    private static func send(fingers: [[(point: CGPoint, offset: TimeInterval)]], name: String,
                             orientation: UIInterfaceOrientation) throws {
        guard let classes, let synthesizer else {
            throw BridgeError(501, "this Xcode has no coordinate gesture support"
                + " (XCPointerEventPath / XCSynthesizedEventRecord are gone)")
        }
        let record = classes.record.init(name: name, interfaceOrientation: orientation.rawValue)
        var totalDuration: TimeInterval = 0
        for keyframes in fingers {
            guard let first = keyframes.first else { continue }
            let path = classes.path.init(touchAt: first.point, offset: first.offset)
            var lastOffset = first.offset
            for keyframe in keyframes.dropFirst() {
                let offset = max(keyframe.offset, lastOffset + minimumOffsetStep)
                path.move(to: keyframe.point, atOffset: offset)
                lastOffset = offset
            }
            path.liftUp(atOffset: lastOffset)
            record.add(path)
            totalDuration = max(totalDuration, lastOffset)
        }
        // 送信は非同期。**ここは HTTP のハンドラ(専用スレッド)なので待ってよい** ——
        // 待たずに返すと、ホストが直後に撮るスナップショットがジェスチャ前の木になる
        let done = DispatchSemaphore(value: 0)
        synthesizer.synthesize(record) { done.signal() }
        if done.wait(timeout: .now() + totalDuration + 10) == .timedOut {
            throw BridgeError(500, "the coordinate gesture did not come back within"
                + " \(Int(totalDuration) + 10)s")
        }
    }
}
