// 画面が「進んでいるか」をランナー自身に申告させる計器(/status の displayIdleSeconds)。
//
// **in-app 側と同じもの**(InAppBridge/Sources/DisplayHeartbeat.swift)。2つのブリッジは
// HTTP 互換なだけで実装は別物(BridgeRouter も HTTP サーバも二重にある)ため、この計器も
// 各々に置く。**片方だけ変えない** —— しきい値の意味がエンジンで割れると、ホストの
// FrozenEvidence.noPresent が engine ごとに別物になる。
//
// なぜ画像でなく拍動なのか、なぜ単独では確定させないのかは in-app 側の説明を参照。
//
// ランナー固有の注意: メインスレッドはテストメソッドが `RunLoop.run(until:)` を回しているので
// 拍動は載る。ただし**リクエスト処理中はメインが専有される**(タップの quiescence 待ち等)ので、
// 操作中は idle が数百 ms 〜 数秒に伸びる。ホスト側のしきい値はこれを見込んで置くこと。

import Foundation
import QuartzCore

final class DisplayHeartbeat {
    static let shared = DisplayHeartbeat()

    private let lock = NSLock()
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var startedAt: CFTimeInterval?

    /// 止まったかどうかしか見ないので 10Hz で足りる(60Hz は 10 台ぶんの無駄)
    private static let preferredFPS = 10

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.link == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
            link.preferredFramesPerSecond = Self.preferredFPS
            link.add(to: .main, forMode: .common)
            self.lock.lock()
            self.link = link
            self.startedAt = CACurrentMediaTime()
            self.lock.unlock()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        lock.lock()
        lastTick = link.timestamp
        lock.unlock()
    }

    /// 最後に画面が進んでからの秒数。計器が動いていなければ nil(= 申告しない)
    var idleSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        guard link != nil, let startedAt else { return nil }
        return max(0, CACurrentMediaTime() - (lastTick ?? startedAt))
    }
}
