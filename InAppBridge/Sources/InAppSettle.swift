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
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in evaluate() }
    }

    private static func anyLayerAnimating() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where layerAnimating(window.layer) { return true }
        }
        return false
    }

    private static func layerAnimating(_ layer: CALayer) -> Bool {
        for key in layer.animationKeys() ?? [] {
            guard let anim = layer.animation(forKey: key) else { continue }
            // 無限反復アニメ(テキストカーソル点滅・アクティビティインジケータ等)は永久に
            // 「整定しない」ので無視する。これを数えると settle が必ず cap に張り付く。
            if anim.repeatCount.isInfinite || anim.repeatCount > 100 { continue }
            if anim.repeatDuration > 1_000_000 { continue }
            return true
        }
        for sub in layer.sublayers ?? [] where layerAnimating(sub) { return true }
        return false
    }
}
