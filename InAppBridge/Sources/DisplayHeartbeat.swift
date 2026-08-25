// 画面が「進んでいるか」をアプリ自身に申告させる計器。
//
// **ホストは凍結判定に使わない。採り直さないこと** —— 「静止画面(tick あり)と wedge
// (tick なし)を画像なしで分離できる」という前提は反証されている: 本物の wedge を故意に
// 起こしても拍動は 0.001〜0.016s で回り続けた。CADisplayLink が測るのは「アプリが vsync を
// 要求しているか」であって「表示が進んだか」ではない(実測は docs/verification.md)。
// 計器を残してあるのは、撤去がブリッジ版上げ = 全台の建て直しを伴うため(次の版上げに便乗する)。
//
// **交絡の注意**: 表示を触り続ける処理そのものが凍結を緩和しうる(アイドル readback を
// 失うと凍結が増えた、という別件の実測がある)。凍結の発生条件を測る対照実験
// (Scripts/freeze-correlation.sh)では、この計器の有無を条件間で必ず揃えること。

import Foundation
import QuartzCore

final class DisplayHeartbeat {
    static let shared = DisplayHeartbeat()

    private let lock = NSLock()
    private var link: CADisplayLink?
    /// 直近 tick の時刻(CACurrentMediaTime 基準)。まだ1回も来ていなければ nil
    private var lastTick: CFTimeInterval?
    /// start() を呼んだ時刻。起動直後に「無限に idle」と申告しないための基準
    private var startedAt: CFTimeInterval?

    /// **60Hz は要らない**(止まったかどうかしか見ない)。10Hz なら 10台のシミュレータで
    /// 回しても負荷が見えず、2秒しきい値に対しても十分な分解能がある
    private static let preferredFPS = 10

    func start() {
        // CADisplayLink はメインの runloop に載せる(vsync に紐づくのはメイン)
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

    /// **最後に画面が進んでからの秒数**。計器が動いていなければ nil(= 申告しない)。
    /// 1回も tick が来ていない間は start() からの経過を返す(起動直後の数百 ms を
    /// 「凍結」と読ませないのはホスト側のしきい値の仕事)
    var idleSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        guard link != nil, let startedAt else { return nil }
        let now = CACurrentMediaTime()
        return max(0, now - (lastTick ?? startedAt))
    }
}
