// 座標を指定する多点ジェスチャの送信口(pinch / gesture / doubletap が共有する)。**XCTest の公開 API には
// ピンチが `XCUIElement` にしか生えておらず**(iOS 27 の SDK を確認)、指の位置は要素の枠から決まる ——
// しかも**縮小は枠の長辺の両端から閉じる**ので、端に別のものが載っていると1本を取られ、ジェスチャが
// パンに化ける(実測 2026-09-22・Apple マップ: 地図の容器の下端が検索カードに接しており、縮小が必ず
// パンになった。公開 API の代替も無い —— 2本指タップは無反応・ダブルタップは拡大しかできない)。
// 座標指定の多点タッチジェスチャそのものにも公開 API が無い(`XCUICoordinate` は単点のみ)。
//
// **指の置き方はこのファイルでは決めない** —— pinch の指の座標はホスト(`FTCore.PinchGesture`)が
// 組んで `PinchRequest.fingers` で送り、gesture は利用者が指定した経路をそのまま運ぶ。ここは
// キーフレームを認識される密度に補間して1つのタッチ列として送るだけ(`synthesize`)。
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

    /// 1つの move に置く時間の下限[秒]。**これより短い move を続けると XCTest が時間を守らない**
    /// (実測 2026-09-25・シミュレータ: 3 秒の直線を 20ms 間隔で送ると 5.4 秒、16.7ms で 4.4 秒、
    /// 8ms で 0.45 秒。33ms 以上なら 3.4〜3.7 秒 = 固定の遅れ約 0.4 秒だけ)。ライブ操作の軌跡は
    /// pointermove ごと(約 16〜20ms)の点を運ぶので、そのままだと再生が伸び、Apple マップは動かなかった。
    /// 33ms が境目だったので余裕を見て 50ms
    private static let minimumSegment: TimeInterval = 0.05

    /// 長い move を割る間隔[秒]。**XCTest は1つの move の中を自分で補間する**(4 秒の1区間でも
    /// ドラッグとして届く = 実測)が、始点と終点だけだと速度が出ずピンチとして認識されないことがある
    /// (recognizer は移動量の履歴を見る)ので数点に割る。`minimumSegment` 以上に保つこと
    /// (以前の 1/60 秒刻みは下限を割り、再生時間が狂っていた)
    private static let maximumSegment: TimeInterval = 0.1

    /// 連続する move に同じ offset を渡さないための最小間隔[秒]。**XCPointerEventPath が厳密な
    /// 単調増加を要求するかは非公開 API なので確認できない** —— キーフレームの間隔が
    /// `minimumSegment` 未満になる静止区間の端などで同一 offset の move が連続しうるので、常にこの床で
    /// 押し上げる。**最後の move → liftUp だけは同じ offset を許す**
    /// (`move(to: to, atOffset: duration)` の直後に `liftUp(atOffset: duration)` — 動いていた実績と
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

    /// 指ごとの粗いキーフレーム(押す点→…→離す点。同じ点が続く区間 = 静止)を、認識されるだけの
    /// 密度に補間してから1つのタッチ列として再生する。pinch / gesture / doubletap の実体
    /// (指の置き方はここでは決めない——呼び手が組んだキーフレームをそのまま運ぶ)
    /// - Parameter fingers: 各指のキーフレーム列。1本目の要素が touch down・最後が lift
    static func synthesize(fingers: [[(point: CGPoint, offset: TimeInterval)]], name: String,
                           orientation: UIInterfaceOrientation) throws {
        try send(fingers: fingers.map(resample), name: name, orientation: orientation)
    }

    /// キーフレームを XCTest が時間どおりに再生できる粒度へ揃える: ①`minimumSegment` 未満の間隔の点を
    /// 間引く(先頭・末尾と、静止区間の端 = 直前か直後と同じ点は必ず残す —— 落とすと静止が移動に化ける)
    /// ②`maximumSegment` を超える移動を割る(静止区間は割らない = 位置が変わらないので終端の1点で足りる)
    private static func resample(_ keyframes: [(point: CGPoint, offset: TimeInterval)])
        -> [(point: CGPoint, offset: TimeInterval)] {
        guard let first = keyframes.first, let last = keyframes.last else { return [] }
        var kept: [(point: CGPoint, offset: TimeInterval)] = [first]
        if keyframes.count > 2 {
            for index in 1..<(keyframes.count - 1) {
                let keyframe = keyframes[index]
                let holdEdge = keyframe.point == keyframes[index - 1].point
                    || keyframe.point == keyframes[index + 1].point
                if holdEdge || keyframe.offset - kept[kept.count - 1].offset >= minimumSegment {
                    kept.append(keyframe)
                }
            }
        }
        if keyframes.count > 1 { kept.append(last) }
        var out: [(point: CGPoint, offset: TimeInterval)] = [first]
        var previous = first
        for keyframe in kept.dropFirst() {
            let span = keyframe.offset - previous.offset
            if keyframe.point == previous.point || span <= maximumSegment {
                out.append(keyframe)
            } else {
                let stepCount = Int((span / maximumSegment).rounded(.up))
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

    /// **SPI に触れる唯一の場所**(pinch / gesture / doubletap が共有する)。フルに展開済みのキーフレームから
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
