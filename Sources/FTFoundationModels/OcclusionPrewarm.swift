// occlusion 1段目のセッションを1つだけ持つ暖機スロット。
//
// **なぜ要るか**: FM の1呼び出しはモデルの積み込みを含み、`session.prewarm()` を**先に**撃つと
// その分だけ待ちが減る。効くのは「重ねられる作業の長さ」ぶん(2026-09-03 実測・20秒アイドル後:
// vision はリード 1000ms で −14% / 250ms で −8% / **直前(0ms)では ±0**)。
// occlusion で重ねられるのはスクショ往復・stale 判定・インク判定なので、
// **`StepExecutor.occlusionFlip` がスクショを撮る前**に撃つ(FTCore からは
// `ReplayDelegate.prewarmVisibilityCheck()` 越し)。
//
// 守る規律4つ:
// ① **instructions が一致したときだけ使う** —— prefill は instructions ごとなので、
//    別の文字列で暖めたセッションを使い回しても何も得しない(むしろ誤解を生む)
// ② **取り出したら捨てる**(`take`)—— respond を通したセッションは会話履歴を持つ。
//    使い回すと2回目以降のプロンプトに前回の crop と判定が混ざる
// ③ **暖機は FMGate を通らない**(門の外)。生成を伴わないので枠を消費させないが、
//    死んでいる FM を暖め続けないよう**ブレーカだけは呼び出し側で見る**
// ④ **FMHealth に記録しない** —— 暖機は「呼び出し」ではないので、記録すると
//    fm.calls とレートが実態より多く見える(FMLivenessProbe と同じ理由)
//
// 置き場が1つなので、直前の暖機が使われないまま次が来たら**捨てて置き換える**
// (Tier-1 のインク足切りで FM を省いた回がこれに当たる)。

import Foundation
import FoundationModels

enum OcclusionPrewarm {

    private static let lock = NSLock()
    private static var stored: (session: LanguageModelSession, instructions: String)?

    /// セッションを1つ作って `prewarm()` を撃ち、スロットへ置く。既にあれば置き換える
    static func prewarm(instructions: String) {
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        lock.lock()
        stored = (session, instructions)
        lock.unlock()
    }

    /// 暖機済みセッションを取り出す(instructions が一致するときだけ)。取り出したら空にする
    static func take(matching instructions: String) -> LanguageModelSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let held = stored, held.instructions == instructions else { return nil }
        stored = nil
        return held.session
    }

    /// テストだけが使う。スロットを空にする
    static func resetForTesting() {
        lock.lock()
        stored = nil
        lock.unlock()
    }

    /// テストだけが使う。スロットが埋まっているか
    static var isHoldingForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored != nil
    }
}
