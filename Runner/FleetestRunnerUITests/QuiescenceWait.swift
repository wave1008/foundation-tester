// QuiescenceWait.swift
// XCUITest が操作の前後に行う暗黙の quiescence 待ち(アプリからのアイドル・アニメーション完了の通知を待つ。XCTest の用語)の扱い。
// **fleetest の「整定」(ホストが木の比較で見る)とは別物** —— ここで待ちを飛ばしても整定はホストが行う。
// XCUIApplicationProcess の private メソッドを swizzle し、`skipping` が true の間は元実装を呼ばず即 return、
// それ以外は上限を縮めて元実装を呼ぶ(cappedWait)。
// - private API 依存: セレクタは Xcode バージョンで変わりうるため候補を全て試し、1つも
//   見つからなければ無効(available=false)として通常動作にフォールバックする。
// - skipping / capArmed はリクエスト処理(main queue 直列。BridgeHTTPServer 参照)からのみ触ること。
// - 注意: type(typeText)には適用しない。キーボード出現待ちを quiescence に依存しているため
//   (BridgeRouter.handleType のコメント参照)、スキップすると入力欠落の実害が出る。
// - **タップ・ダブルタップ・長押しは既定で待ちを飛ばす**(QuiescenceWait.around の skipByDefault)。/drag(handleDrag)はここを通らない
// - **飛ばさない回(スワイプ = スクロールを含む)も、操作(QuiescenceWait.around の中)の間だけ待ちの上限を
//   `quiescenceCapSeconds` に縮める**(cappedWait)。起動・前面化・入力の中の待ちは縮めない —— activate の中の待ちを
//   切ると前面化そのものが完了せずホストが 45s で時間切れになった(実測)。XCTest の上限は
//   全体で共有の `_XCTApplicationStateTimeout()`(既定 60s。起動・前面化・終了・URL も同じ値を使う)なので、
//   待ちの直前だけ `_XCTSetApplicationStateTimeout` で差し替えて戻す(WDA と同じ形)

import Foundation
import ObjectiveC

enum QuiescenceWait {
    /// true の間、swizzle 済み quiescence 待ちが no-op になる(待ちを飛ばす)(リクエスト毎に立てて必ず戻す)
    static var skipping = false
    /// swizzle が1つ以上成功したか(/status の quiescenceControlAvailable として申告)
    private(set) static var available = false

    /// 計測用: resetTiming() 以降に **元の quiescence 待ちの中で消えた時間**(ms)。
    /// swizzle が入っている経路しか数えられないので、**available == false のときは常に 0**
    /// (「整定待ちが無かった」ではなく「測れていない」。読み手はここを取り違えないこと)。
    private(set) static var quiescenceMs: Double = 0
    static func resetTiming() { quiescenceMs = 0 }

    private static func addQuiescence(since start: DispatchTime) {
        quiescenceMs += Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    /// XCTest の「アプリが落ち着くまで待つ」の上限[秒](ユーザー決定)。実測(Simulator・ランナー5台のログ・約 1,400 回):
    /// 正常な待ちは中央値 0.01〜0.1s・95% 点 1〜1.6s・最大 5.1s。知らせが来ないアプリ(Apple マップで観測)は
    /// 既定の 60s まで止まり、その間ランナーは /status も返せない。尽きたら XCTest は知らせ無しで続行し
    /// ("App animations complete notification not received")、整定は木の観察(captureSettled 等)が担う。
    /// 尽きた回は応答の注記に出す(`takeCapNote`)。**正常な待ちの最大より短くしない** —— 上限は「イベントループが空いた」
    /// 知らせの待ちにも効き、アプリが実際に忙しいときにそれを打ち切ると、続く処理が別の待ちで長く止まる(上限 0.3s の
    /// 陽性対照で、打ち切りの後に元の待ちが戻るまで約 50s。アニメーション完了の知らせの打ち切りは問題なく続行した)
    static let quiescenceCapSeconds: TimeInterval = 6

    private typealias TimeoutGetter = @convention(c) () -> Double
    private typealias TimeoutSetter = @convention(c) (Double) -> Void
    /// XCUIAutomation の非公開 C 関数(nm で `__XCTApplicationStateTimeout`)。無い Xcode では nil = 縮めない
    private static let timeoutGetter: TimeoutGetter? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                              "_XCTApplicationStateTimeout")
        .map { unsafeBitCast($0, to: TimeoutGetter.self) }
    private static let timeoutSetter: TimeoutSetter? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                              "_XCTSetApplicationStateTimeout")
        .map { unsafeBitCast($0, to: TimeoutSetter.self) }
    /// 入れ子の待ち(XCUIApplication → XCUIApplicationProcess)で、差し替えと戻しをいちばん外側だけで行う
    private static var capDepth = 0
    /// 上限まで待った回数(リクエストごとに takeCapNote が読んで消す)
    private static var capHits = 0
    /// true の間だけ待ちの上限を縮める(QuiescenceWait.around が操作の間だけ立てる)
    private static var capArmed = false

    /// 元の待ちを、上限を縮めた状態で呼ぶ。上限の関数が無ければそのまま呼ぶ
    private static func cappedWait(_ wait: () -> Void) {
        guard capArmed, let get = timeoutGetter, let set = timeoutSetter else { return wait() }
        let outermost = capDepth == 0
        var previous = 0.0
        if outermost {
            previous = get()
            set(min(previous, quiescenceCapSeconds))
        }
        capDepth += 1
        let start = DispatchTime.now()
        wait()
        capDepth -= 1
        if outermost {
            set(previous)
            // 上限ちょうどで抜けた = 知らせが来なかった(XCTest の続行の処理ぶんの余裕を引いて判定する)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            if elapsed >= quiescenceCapSeconds - 0.2 {
                capHits += 1
                NSLog("[fleetest] quiescence: no idle notification within %.0fs — continued", quiescenceCapSeconds)
            }
        }
    }

    /// 直前の操作で上限まで待ったなら注記を返して数え直す(応答の OKResponse.note へ載せる)
    static func takeCapNote() -> String? {
        defer { capHits = 0 }
        guard capHits > 0 else { return nil }
        return "XCTest did not report the app idle within \(Int(quiescenceCapSeconds))s (animations still running),"
            + " so the action went ahead without waiting further"
    }

    /// ランナー起動時に1回だけ呼ぶ。既知の quiescence 待ちセレクタ候補を全て swizzle する
    /// (呼び出し経路が複数あるため、見つかったものは全部差し替える)。
    static func installSwizzle() {
        guard let cls = NSClassFromString("XCUIApplicationProcess") else {
            NSLog("[fleetest] QuiescenceWait: XCUIApplicationProcess が見つかりません(無効)")
            return
        }
        // 候補は歴代 Xcode で観測されている signature(引数 Bool 0〜2個)
        let candidates: [(name: String, boolArgs: Int)] = [
            ("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:", 2),
            ("waitForQuiescenceIncludingAnimationsIdle:", 1),
            ("_waitForQuiescence", 0),
        ]
        for candidate in candidates {
            let sel = NSSelectorFromString(candidate.name)
            guard let method = class_getInstanceMethod(cls, sel) else { continue }
            let original = method_getImplementation(method)
            switch candidate.boolArgs {
            case 2:
                typealias Fn = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
                let orig = unsafeBitCast(original, to: Fn.self)
                let block: @convention(block) (AnyObject, Bool, Bool) -> Void = { obj, a, b in
                    if QuiescenceWait.skipping { return }
                    let start = DispatchTime.now()
                    QuiescenceWait.cappedWait { orig(obj, sel, a, b) }
                    QuiescenceWait.addQuiescence(since: start)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            case 1:
                typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
                let orig = unsafeBitCast(original, to: Fn.self)
                let block: @convention(block) (AnyObject, Bool) -> Void = { obj, a in
                    if QuiescenceWait.skipping { return }
                    let start = DispatchTime.now()
                    QuiescenceWait.cappedWait { orig(obj, sel, a) }
                    QuiescenceWait.addQuiescence(since: start)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            default:
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                let orig = unsafeBitCast(original, to: Fn.self)
                let block: @convention(block) (AnyObject) -> Void = { obj in
                    if QuiescenceWait.skipping { return }
                    let start = DispatchTime.now()
                    QuiescenceWait.cappedWait { orig(obj, sel) }
                    QuiescenceWait.addQuiescence(since: start)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
            available = true
            NSLog("[fleetest] QuiescenceWait: swizzled %@", candidate.name)
        }
        if !available {
            NSLog("[fleetest] QuiescenceWait: quiescence セレクタが1つも見つかりません(無効・通常動作)")
        }
        // 起動時に1行(上限の口が消えたことが run を待たずに分かる)
        NSLog("[fleetest] quiescence cap: %@", (available && timeoutGetter != nil && timeoutSetter != nil)
            ? "\(Int(quiescenceCapSeconds))s" : "unavailable (XCTest's own limit applies)")
    }

    /// リクエスト単位の一時有効化(available でなければ何もしない)。`skipByDefault` はリクエストが `skipQuiescence` を言わないときの既定:
    /// **タップ・ダブルタップ・長押しは true**(待ちを飛ばし、整定は木の観察 = captureSettled が担う)/
    /// **スワイプ(スクロールを含む)は false**(待ちを残す。慣性の終わりを木では見届けられず、RN の横スクロール E2E-RN S0090 が
    /// 6 回中 4 回落ちた —— 探索が対象を見つけて止まった後も慣性で流れて画面外へ出る。タップ系は 4 SUT で退行無し。
    /// 実測と経緯は docs/performance-tuning.md §8)。`skipQuiescence: true` はどちらも飛ばす(ホストは簡易整定モード = iosLightSettle / DSL の `lightSettle:` のときにこれを送る。
    /// 簡易整定モード = 整定を木の比較だけに任せるモードで、そのために XCTest の待ちを外すのがこの欄)
    static func around<T>(_ skipQuiescence: Bool?, skipByDefault: Bool = false, _ body: () throws -> T) rethrows -> T {
        guard available, skipQuiescence ?? skipByDefault else {
            capArmed = true
            defer { capArmed = false }
            return try body()
        }
        // 検証用(簡易整定モードでホストが skipQuiescence: true を送ったことの確認)。タップ系は既定で毎回ここを通るので、明示の skipQuiescence: true のときだけ出す
        if skipQuiescence == true { NSLog("[fleetest] QuiescenceWait: skipping (light settle)") }
        skipping = true
        defer { skipping = false }
        return try body()
    }
}
