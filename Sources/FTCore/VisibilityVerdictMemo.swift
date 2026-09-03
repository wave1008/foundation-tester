// occlusion-guard の FM 可視性判定の控え。
//
// 鍵は **FM への入力そのもの**(スクショのバイト列の hash・frame・screen・期待文字列)。FM は同一画像に
// 対して決定的(greedy。92_screenLooksLike のヘッダの実測)なので、同じ鍵には同じ答えしか返らない =
// 控えを返しても検査の意味は1つも落ちない。落ちるのは FM の 1.5〜5 秒だけ。
//
// **控えは直近のスクショ1枚ぶんだけ**: 画面がバイト単位で変わった瞬間に丸ごと捨てる。
// 上限の定数を置かないための形(1画面で控えられる件数は guard 対象の要素数を超えない)。
// **nil(答え無し)は控えない** —— 次は必ず訊き直す(死活・ブレーカの回復を見逃さない)。
//
// 効く場面: `select(...).textIs(...)` のように同じ要素を続けて確かめる書き方。E2E-iOS の
// ジェスチャ S0010 は FM 60 回中ほぼ半分がこの重複で、M1Ultra(vision ≈ 2.6s/回)では 158s =
// 180s の予算超え(2026-09-04)。

import Foundation

public struct VisibilityVerdictMemo {
    public typealias Verdict = (visible: Bool, state: String, reason: String, observedText: String)

    public struct Key: Hashable {
        let x: Double, y: Double, width: Double, height: Double
        let screenWidth: Double, screenHeight: Double
        let expectedText: String
    }

    private var imageHash: Int?
    private var verdicts: [Key: Verdict] = [:]

    public init() {}

    public static func key(frame: FTRect, screen: FTRect, expectedText: String) -> Key {
        Key(x: frame.x, y: frame.y, width: frame.width, height: frame.height,
            screenWidth: screen.width, screenHeight: screen.height, expectedText: expectedText)
    }

    /// 同じスクショ(hash 一致)に対する同じ鍵の控え。別のスクショなら nil
    public func lookup(imageHash: Int, key: Key) -> Verdict? {
        guard self.imageHash == imageHash else { return nil }
        return verdicts[key]
    }

    /// スクショが変わっていたら控えを丸ごと捨ててから入れる
    public mutating func store(imageHash: Int, key: Key, verdict: Verdict) {
        if self.imageHash != imageHash {
            self.imageHash = imageHash
            verdicts.removeAll()
        }
        verdicts[key] = verdict
    }

    /// テスト用: 今持っている控えの件数
    public var count: Int { verdicts.count }
}
