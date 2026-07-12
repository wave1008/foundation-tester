// アクション後の整定待ち(プロセス内・イベント駆動)。Android の QuietWaiter の iOS 版。
// CFRunLoopObserver(beforeWaiting)でアニメーション有無を観測し、無アニメが quietMs 継続で整定。
// 走行中アニメがランループを起こし続けない場面のため 16ms ハートビートで再評価を促す
// (再評価トリガであって、アニメ検知自体はイベント駆動)。cap 到達は整定失敗ではなく打ち切り。

import UIKit
import QuartzCore

enum InAppSettle {

    /// メインスレッドで呼ぶこと。整定または cap 到達で done をメインで1回だけ呼ぶ。
    static func waitOnMain(quietMs: Int = 100, capMs: Int = 2500, done: @escaping () -> Void) {
        let start = CACurrentMediaTime()
        var lastBusy = start
        var finished = false
        var observer: CFRunLoopObserver?
        var heartbeat: Timer?

        func finish() {
            if finished { return }
            finished = true
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            heartbeat?.invalidate()
            done()
        }

        func evaluate() {
            let now = CACurrentMediaTime()
            if anyLayerAnimating() { lastBusy = now }
            let quietFor = (now - lastBusy) * 1000
            let elapsed = (now - start) * 1000
            if quietFor >= Double(quietMs) || elapsed >= Double(capMs) { finish() }
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
        let chrome = isDecorativeChrome(layer)
        for key in layer.animationKeys() ?? [] {
            // 無限反復(カーソル点滅・スピナー)と iOS27 Liquid Glass のモーフ(match-*/punchout。
            // タブバー等が常時走らせる装飾で UI 整定信号ではない)は無視。数えると必ず cap 張り付き。
            if chrome || key.contains("match") || key.contains("punchout") { continue }
            guard let anim = layer.animation(forKey: key) else { continue }
            if anim.repeatCount.isInfinite || anim.repeatCount > 100 { continue }
            if anim.repeatDuration > 1_000_000 { continue }
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
}
