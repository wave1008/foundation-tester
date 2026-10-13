// occlusion 1段目のセッションを1つだけ持つ先読みスロット。
//
// **なぜ要るか**: FM の1呼び出しはモデルの積み込みを含み、`session.prewarm()` を**先に**撃つと
// その分だけ待ちが減る。効くのは「重ねられる作業の長さ」ぶん(実測・20秒アイドル後:
// vision はリード 1000ms で −14% / 250ms で −8% / **直前(0ms)では ±0**)。
// occlusion で重ねられるのはスクショ往復・stale 判定・インク判定なので、
// **`StepExecutor.occlusionFlip` がスクショを撮る前**に撃つ(FTCore からは
// `ReplayDelegate.preloadVisibilityCheck()` 越し)。
//
// 守る規律5つ:
// ① **instructions が一致したときだけ使う** —— prefill は instructions ごとなので、
//    別の文字列で先読みしたセッションを使い回しても何も得しない(むしろ誤解を生む)
// ② **取り出したら捨てる**(`take`)—— respond を通したセッションは会話履歴を持つ。
//    使い回すと2回目以降のプロンプトに前回の crop と判定が混ざる
// ③ **先読みは FMGate を通らない**(門の外)。生成を伴わないので枠を消費させないが、
//    死んでいる FM を先読みし続けないよう**ブレーカだけは呼び出し側で見る**
// ④ **FMHealth に記録しない** —— 先読みは「呼び出し」ではないので、記録すると
//    fm.calls とレートが実態より多く見える(FMLivenessProbe と同じ理由)
// ⑤ **使われていない同じ instructions のセッションがあれば作り直さず `prewarm()` だけ撃ち直す**。
//    セッションを1つ作るたびに modelmanagerd が安全判定のモデル(instruct_300m.safety)のセッションを作り、
//    その実体を ANE に載せる。ガード評価ごとに作り捨てると(FM を実際に呼ぶのは全体実行で数回なのに)
//    8 並列で毎分 500〜800 セッションになり、ANE が `no memory` で溢れて FM と OCR が再起動まで死んだ
//    (M2Ultra の E2E 一式で実測。docs/open-issues.md の記録)。
//    未使用の先読みセッションは会話履歴を持たないので、使い回しても②に反しない

import Foundation
import FoundationModels
import Synchronization

/// 先読みスロットの規則(FM に依存しない = 単体テストで偽のセッションを差して確かめる)
final class PreloadSlot<Session: AnyObject>: Sendable {
    private let stored = Mutex<(session: UncheckedSession, instructions: String)?>(nil)

    /// 非 Sendable のセッションを Mutex の内側だけで持つための包み(取り出した後は呼び手の単独所有)
    private struct UncheckedSession: @unchecked Sendable { let value: Session }

    /// 同じ instructions の未使用セッションがあれば `warm` だけ撃ち直す。無ければ `make` で作って `warm` し、置く
    /// (別の instructions のセッションは置き換える)
    func preload(instructions: String, make: (String) -> Session, warm: (Session) -> Void) {
        let existing = stored.withLock { slot -> Session? in
            guard let held = slot, held.instructions == instructions else { return nil }
            return held.session.value
        }
        if let existing {
            warm(existing)
            return
        }
        let session = make(instructions)
        warm(session)
        stored.withLock { $0 = (UncheckedSession(value: session), instructions) }
    }

    /// 先読み済みセッションを取り出す(instructions が一致するときだけ)。取り出したら空にする
    func take(matching instructions: String) -> Session? {
        stored.withLock { slot in
            guard let held = slot, held.instructions == instructions else { return nil }
            slot = nil
            return held.session.value
        }
    }

    func reset() {
        stored.withLock { $0 = nil }
    }

    var isHolding: Bool {
        stored.withLock { $0 != nil }
    }
}

enum OcclusionPreload {

    private static let slot = PreloadSlot<LanguageModelSession>()

    /// 先読みを撃つ。使われていない同じ instructions のセッションがあればそれを暖め直すだけ(規律⑤)
    static func preload(instructions: String) {
        slot.preload(instructions: instructions,
                     make: { LanguageModelSession(instructions: $0) },
                     warm: { $0.prewarm() })
    }

    /// 先読み済みセッションを取り出す(instructions が一致するときだけ)。取り出したら空にする
    static func take(matching instructions: String) -> LanguageModelSession? {
        slot.take(matching: instructions)
    }

    /// テストだけが使う。スロットを空にする
    static func resetForTesting() {
        slot.reset()
    }

    /// テストだけが使う。スロットが埋まっているか
    static var isHoldingForTesting: Bool {
        slot.isHolding
    }
}
