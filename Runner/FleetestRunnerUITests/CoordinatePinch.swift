// 座標を指定する2本指ピンチ。**XCTest の公開 API にはピンチが `XCUIElement` にしか生えておらず**
// (iOS 27 の SDK を確認)、指の位置は要素の枠から決まる —— しかも**縮小は枠の長辺の両端から
// 閉じる**ので、端に別のものが載っていると1本を取られ、ジェスチャがパンに化ける
// (実測 2026-09-22・Apple マップ: 地図の容器の下端が検索カードに接しており、縮小が必ずパンになった。
// 公開 API の代替も無い —— 2本指タップは無反応・ダブルタップは拡大しかできない)。
//
// そこで **Appium/WebDriverAgent と同じ非公開 API** で2本指の経路を自分で組む。
// クラスは `XCPointerEventPath` / `XCSynthesizedEventRecord`(**`XCUI` 接頭辞は付かない**。
// 公開ヘッダには宣言が無い)。
//
// **非公開なので必ず実行時に確かめてから使う** —— Xcode の更新で消えうる(同じ調査で
// `XCTRunnerDaemonSession` が Xcode 27 の XCUIAutomation に無いことを確認した)。
// 無ければ `isAvailable == false` を返し、呼び手は公開 API の経路へ縮退する。
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

    /// 指を動かす分割数。**1本の直線を数点に割る** —— 始点と終点だけだと速度が出ず、
    /// ピンチとして認識されないことがある(recognizer は移動量の履歴を見る)
    private static let steps = 12

    /// 押してから動き出すまで / 止まってから離すまでに置く時間(所要に対する割合)
    private static let holdRatio = 0.2

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
        guard let classes, let synthesizer else {
            throw BridgeError(501, "this Xcode has no coordinate pinch"
                + " (XCPointerEventPath / XCSynthesizedEventRecord are gone)")
        }
        let record = classes.record.init(name: "fleetest pinch",
                                         interfaceOrientation: orientation.rawValue)
        // **押した直後に動かさない・離す直前に止める** —— 押下と最初の移動が同じ時刻だと、
        // recognizer が開始を取りこぼすことがある(XCTest 自身のジェスチャも前後に間を置く)。
        // 保持は前後それぞれこの割合
        let hold = duration * holdRatio
        let travel = duration - hold * 2
        for (from, to) in [(start.0, end.0), (start.1, end.1)] {
            let path = classes.path.init(touchAt: from, offset: 0)
            path.move(to: from, atOffset: hold)
            for step in 1...steps {
                let ratio = Double(step) / Double(steps)
                path.move(to: CGPoint(x: from.x + (to.x - from.x) * ratio,
                                      y: from.y + (to.y - from.y) * ratio),
                          atOffset: hold + travel * ratio)
            }
            path.move(to: to, atOffset: duration)
            path.liftUp(atOffset: duration)
            record.add(path)
        }
        // 送信は非同期。**ここは HTTP のハンドラ(専用スレッド)なので待ってよい** ——
        // 待たずに返すと、ホストが直後に撮るスナップショットがジェスチャ前の木になる
        let done = DispatchSemaphore(value: 0)
        synthesizer.synthesize(record) { done.signal() }
        if done.wait(timeout: .now() + duration + 10) == .timedOut {
            throw BridgeError(500, "the coordinate pinch did not come back within"
                + " \(Int(duration) + 10)s")
        }
    }
}
