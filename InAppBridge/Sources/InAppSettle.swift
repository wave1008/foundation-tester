// アクション後の整定待ち(プロセス内・イベント駆動)。Android の QuietWaiter の iOS 版。
// CFRunLoopObserver(beforeWaiting)でアニメーション有無を観測し、無アニメが quietMs 継続で整定。
// 走行中アニメがランループを起こし続けない場面のため 16ms ハートビートで再評価を促す
// (再評価トリガであって、アニメ検知自体はイベント駆動)。cap 到達は整定失敗ではなく打ち切り。

import UIKit
import QuartzCore

enum InAppSettle {

    /// メインスレッドで呼ぶこと。整定または cap 到達で done をメインで1回だけ呼ぶ。
    ///
    /// `done` の引数は **converged**(true = 無アニメが quietMs 続いた / false = cap 打ち切り)。
    /// **打ち切りを黙って返さない**のが要点: 常態的に cap へ張り付いていても結果は同じ顔で返るため、
    /// 「動くが毎回 2.5 秒遅い」が誰にも見えないまま残る(実際 scroll edge effect のぼかしで
    /// そうなっていた。2026-07-31)。呼び出し側は note にしてホストのレポートへ出す
    static func waitOnMain(quietMs: Int = 100, capMs: Int = 2500,
                           done: @escaping (_ converged: Bool) -> Void) {
        let start = CACurrentMediaTime()
        var lastBusy = start
        lastOffsets = [:]   // 前回の待ちの残骸を「動いた」と誤読しない
        var finished = false
        var observer: CFRunLoopObserver?
        var heartbeat: Timer?

        func finish(_ converged: Bool) {
            if finished { return }
            finished = true
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            heartbeat?.invalidate()
            done(converged)
        }

        func evaluate() {
            let now = CACurrentMediaTime()
            if anyLayerAnimating() || anyScrollViewMoving() { lastBusy = now }
            let quietFor = (now - lastBusy) * 1000
            let elapsed = (now - start) * 1000
            if quietFor >= Double(quietMs) { finish(true) }
            else if elapsed >= Double(capMs) { finish(false) }
        }

        observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in evaluate() }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        // Timer.scheduledTimer は default モードのみ。トラッキングモード(スクロール等)でも
        // ハートビートが止まらないよう commonModes で追加する。
        let timer = Timer(timeInterval: 0.016, repeats: true) { _ in evaluate() }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// 直前の評価時点の contentOffset(スクロールの動きを差分で見るため)
    private static var lastOffsets: [ObjectIdentifier: CGPoint] = [:]

    /// **スクロールが動いているか**。`setContentOffset(animated: true)`(「先頭へ」等の
    /// プログラム的スクロール)は **CALayer のアニメーションを伴わない**ため
    /// `anyLayerAnimating` をすり抜ける。すり抜けると tap が「整定済み」で返り、直後の
    /// snapshot が**動く前のツリー**を返す —— ステップは成功のまま別の要素が掴まれる
    /// (2026-08-02 実測: 「先頭へ」直後のスクロール探索が1回も送らずに古い座標をタップした)。
    /// 動き自体を差分で見るのが唯一の確実な信号(isDragging/isDecelerating は
    /// プログラム的スクロールでは立たない)
    private static func anyScrollViewMoving() -> Bool {
        var moving = false
        var seen: [ObjectIdentifier: CGPoint] = [:]
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            guard let key = windowScene.windows.first(where: { $0.isKeyWindow }) else { continue }
            var stack: [UIView] = [key]
            while let view = stack.popLast() {
                if let sv = view as? UIScrollView, !sv.isHidden, sv.alpha > 0.01 {
                    let id = ObjectIdentifier(sv)
                    seen[id] = sv.contentOffset
                    if let previous = lastOffsets[id], previous != sv.contentOffset { moving = true }
                }
                stack.append(contentsOf: view.subviews)
            }
        }
        lastOffsets = seen
        return moving
    }

    private static func anyLayerAnimating() -> Bool {
        // 各シーンのキーウィンドウを対象にする(キーボード/システムウィンドウは予測変換バー等の
        // 永続アニメを持つことがあり、含めると settle が cap に張り付く)。複数シーンのいずれかが
        // アニメ中なら整定していないとみなす。
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            guard let key = windowScene.windows.first(where: { $0.isKeyWindow }) else { continue }
            if layerAnimating(key.layer) { return true }
        }
        return false
    }

    private static func layerAnimating(_ layer: CALayer) -> Bool {
        let keys = layer.animationKeys() ?? []
        // chrome 判定は keys が空だと結果を使わない。実測でレイヤの 99% が空で、settle 1回は
        // ツリー全層を約27回歩くため、無条件に計算すると中央値 1.9ms を捨てる(2026-07-30 計測)
        let chrome = keys.isEmpty ? false : isDecorativeChrome(layer)
        for key in keys {
            // 無限反復(カーソル点滅・スピナー)と iOS27 Liquid Glass のモーフ(match-*/punchout。
            // タブバー等が常時走らせる装飾で UI 整定信号ではない)は無視。数えると必ず cap 張り付き。
            if chrome || key.contains("match") || key.contains("punchout") { continue }
            guard let anim = layer.animation(forKey: key) else { continue }
            if anim.repeatCount.isInfinite || anim.repeatCount > 100 { continue }
            if anim.repeatDuration > 1_000_000 { continue }
            if isVisualEffectParameter((anim as? CAPropertyAnimation)?.keyPath ?? key) { continue }
            return true
        }
        for sub in layer.sublayers ?? [] where layerAnimating(sub) { return true }
        return false
    }

    // iOS27 Liquid Glass の SDF/レンズ系レイヤは常時モーフィングして settle しない
    private static func isDecorativeChrome(_ layer: CALayer) -> Bool {
        let name = String(describing: type(of: layer))
        return name.contains("SDF") || name.contains("LiquidLens")
    }

    /// ぼかし等**視覚効果パラメータ**のアニメーションか。これは「画面がまだ動いている」信号ではない。
    ///
    /// 具体的には iOS26/27 の scroll edge effect(スクロール縁のぼかし)。実測(2026-07-31)で
    /// `CABackdropLayer` が `filters.gaussianBlur.inputRadius` を 0.25s で animate し続け、
    /// **無限反復でないので既存の除外に掛からない**まま quietMs 100ms の無アニメ区間を作らせず、
    /// launch 直後の 1〜2 アクションが毎回 cap(2500ms)に張り付いていた
    /// (Compose iOS で actionMs 2,521ms。同じ操作は温まった後なら 107ms)。
    /// **位置・不透明度・transform は除外しない**ので、本物の画面遷移の待ちは従来どおり効く
    private static func isVisualEffectParameter(_ keyPath: String) -> Bool {
        keyPath.hasPrefix("filters.") || keyPath.hasPrefix("backdropFilters.")
    }
}
