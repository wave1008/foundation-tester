// FastInput.swift
// レバー1 PoC: XCUITest がタップ等の前に行う暗黙の quiescence 待ち(アプリのアイドル+
// アニメーション整定)をスキップする高速入力。XCUIApplicationProcess の private メソッドを
// swizzle し、`enabled` が true の間だけ元実装を呼ばず即 return する。
// - private API 依存: セレクタは Xcode バージョンで変わりうるため候補を全て試し、1つも
//   見つからなければ無効(available=false)として通常動作にフォールバックする。
// - enabled はリクエスト処理(main queue 直列。BridgeHTTPServer 参照)からのみ触ること。
// - 注意: type(typeText)には適用しない。キーボード出現待ちを quiescence に依存しているため
//   (BridgeRouter.handleType のコメント参照)、スキップすると入力欠落の実害が出る。

import Foundation
import ObjectiveC

enum FastInput {
    /// true の間、swizzle 済み quiescence 待ちが no-op になる(リクエスト毎に立てて必ず戻す)
    static var enabled = false
    /// swizzle が1つ以上成功したか(/status の fastInputAvailable として申告)
    private(set) static var available = false

    /// 計測用: resetTiming() 以降に **元の quiescence 待ちの中で消えた時間**(ms)。
    /// swizzle が入っている経路しか数えられないので、**available == false のときは常に 0**
    /// (「整定待ちが無かった」ではなく「測れていない」。読み手はここを取り違えないこと)。
    private(set) static var quiescenceMs: Double = 0
    static func resetTiming() { quiescenceMs = 0 }

    private static func addQuiescence(since start: DispatchTime) {
        quiescenceMs += Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    /// ランナー起動時に1回だけ呼ぶ。既知の quiescence 待ちセレクタ候補を全て swizzle する
    /// (呼び出し経路が複数あるため、見つかったものは全部差し替える)。
    static func installSwizzle() {
        guard let cls = NSClassFromString("XCUIApplicationProcess") else {
            NSLog("[ftester] FastInput: XCUIApplicationProcess が見つかりません(無効)")
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
                    if FastInput.enabled { return }
                    let start = DispatchTime.now()
                    orig(obj, sel, a, b)
                    FastInput.addQuiescence(since: start)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            case 1:
                typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
                let orig = unsafeBitCast(original, to: Fn.self)
                let block: @convention(block) (AnyObject, Bool) -> Void = { obj, a in
                    if FastInput.enabled { return }
                    let start = DispatchTime.now()
                    orig(obj, sel, a)
                    FastInput.addQuiescence(since: start)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            default:
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                let orig = unsafeBitCast(original, to: Fn.self)
                let block: @convention(block) (AnyObject) -> Void = { obj in
                    if FastInput.enabled { return }
                    let start = DispatchTime.now()
                    orig(obj, sel)
                    FastInput.addQuiescence(since: start)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
            available = true
            NSLog("[ftester] FastInput: swizzled %@", candidate.name)
        }
        if !available {
            NSLog("[ftester] FastInput: quiescence セレクタが1つも見つかりません(無効・通常動作)")
        }
    }

    /// リクエスト単位の一時有効化(available でなければ何もしない)
    static func with<T>(_ fast: Bool?, _ body: () throws -> T) rethrows -> T {
        guard available, fast == true else { return try body() }
        NSLog("[ftester] FastInput: engaged")  // 検証用(fast リクエストの発火確認)
        enabled = true
        defer { enabled = false }
        return try body()
    }
}
