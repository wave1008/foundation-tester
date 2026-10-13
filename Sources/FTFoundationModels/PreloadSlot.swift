// FM の常駐プロセス(FMServeServer)が持つ「予備のセッション」1 つ分の規則。FM に依存しない = 単体テストで偽のセッションを差す。
//
// 守る規律3つ:
// ① **instructions が一致したときだけ使う** —— prefill は instructions ごとなので、別の文字列で暖めたセッションを
//    使い回しても何も得しない
// ② **取り出したら捨てる**(`take`)—— respond を通したセッションは会話履歴を持つ。使い回すと 2 回目以降の
//    プロンプトに前回の crop と判定が混ざる
// ③ **使われていない同じ instructions のセッションがあれば作り直さず暖め直すだけ**。セッションを 1 つ作るたびに
//    modelmanagerd が安全判定のモデルのセッションを作る(作り捨てを繰り返すと積み下ろしが絶えず起きる。
//    docs/maintainer-notes.md §81)。未使用のセッションは会話履歴を持たないので、使い回しても②に反しない

import Foundation
import Synchronization

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

    /// 暖めたセッションを取り出す(instructions が一致するときだけ)。取り出したら空にする
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
