// 画面が「進んでいるか」をアプリ自身に申告させる計器。
//
// **なぜ要るか**: 凍結の判定はこれまで「絵が一様(白/黒ベタ)か」という代理指標だけだった。
// これは blank 型しか捕まえず、最後のフレームが残る固着型は非一様なので原理的に当たらない。
// CADisplayLink は vsync 由来なので**画面の中身が変わらなくても tick し続ける** ——
// つまり「静止画面(tick あり)」と「表示スタックが wedge(tick なし)」を、
// 画像を一切見ずに分離できる**唯一の信号**になる。
//
// **未検証**(2026-08-11): この wedge のときに本当に tick が止まるかは実測前。
// ホスト側は `FrozenEvidence.noPresent` を**単独では確定根拠にしない**(警告のみ)。
// 実デバイスで確認できたら `FrozenEvidence.noPresent.isConclusive` を true にする。
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
