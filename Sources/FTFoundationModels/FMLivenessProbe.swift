// FM の死活を**実際に1回呼んで**確かめ、機械グローバルな台帳(FTCore.FMLiveness)へ書く。
//
// なぜ availability では足りないか: `.available` のまま全呼び出しが失敗する状態が実在する
// (2026-07-22 実測。以後 [[fm-flap-ane-load-failure]] として何度も再発)。逆向き
// (`unavailable`)は嘘をつかないので、そちらは呼ばずに死と断じてよい。
//
// なぜ text と vision を別に撃つか: **独立に死ぬ・戻る**(実測)。text だけ確かめて「生きている」と
// 配ると、occlusion-guard(視覚系)が全滅した機械で誤った緑を量産する。
//
// **実仕事の邪魔をしない**ための門が3つ(`refresh`):
//  ① 台帳が新しければ撃たない(run 中は実呼び出しが台帳を養い続けるので、そもそも撃たない)
//  ② ブレーカが落ちているなら撃たない(死んでいると分かっているものに時間を捨てない)
//  ③ FMLock を**短い timeout** で取り、取れなければ撃たない —— 死活確認のために
//     実行中の run を待たせない。probeLockTimeoutSeconds の doc 参照
//
// **FMHealth / FMUsageLedger には書かない**。プローブは「仕事」ではないので、書くと
// モニターの FM レートが誰も走らせていないのに動く(= 測る対象を自分で消費して見せる)。
// ブレーカだけは養う —— あれは「無駄打ちを止める」ための事実で、プローブの成否も同じ事実。

import Foundation
import FoundationModels
import FTCore

public enum FMLivenessProbe {
    /// 台帳を取り直す間隔。**FM の間欠死の観測に使ってきた刻みと同じ**
    /// (Scripts/fm-flap-monitor.swift を 60 秒で回してきた。数分〜数時間で切り替わる事象に対し
    /// 十分細かく、1回 1〜2 秒の実呼び出しを 60 秒に1回なら実仕事への割り込みも小さい)。
    /// 実際に撃つのは「誰も FM を使っていない」ときだけ(refresh の門①③)
    public static let probeIntervalSeconds: TimeInterval = 60

    /// プローブが FMLock を待つ上限。**通常の 20 秒(FMLock.defaultTimeoutSeconds)は使わない** ——
    /// 死活確認は待ってでも撃つ価値のある仕事ではなく、枠が埋まっている = 実仕事が FM を
    /// 使えている = そちらの成否が台帳を養う、という状況だから。取れなければ黙って諦める
    static let probeLockTimeoutSeconds: TimeInterval = 1

    /// 死活確認の実呼び出しに許す出力トークン。**答えの中身は見ない**(呼べたかどうかだけ)
    private static let maxResponseTokens = 8

    /// 台帳が古い経路だけを実呼び出しで取り直す。返すのは**取り直した後の読み**。
    /// `maxAge` は「これより新しければ撃たない」境目(既定 = プローブ間隔)。
    @discardableResult
    public static func refresh(maxAge: TimeInterval = probeIntervalSeconds,
                              now: Date = Date()) async -> FMLiveness.Reading {
        var stale: [FMLiveness.Path] = []
        let current = FMLiveness.current(now: now, maxAge: maxAge)
        // ① 新しければ撃たない
        if current.text == nil { stale.append(.text) }
        // vision は macOS 27+ でしか存在しない。**非対応は「死」ではない**ので台帳に書かない
        // (能力の話は FMVisionSupport が持つ。混ぜると「OS を上げろ」が「FM が死んだ」に化ける)
        if FMVisionSupport.isSupported, current.vision == nil { stale.append(.vision) }
        guard !stale.isEmpty else { return FMLiveness.current(now: now) }

        // availability が unavailable を返す向きだけは信じてよい(ファイル冒頭)。呼ばずに決まる
        let availability = FMDoctor.check()
        if !availability.available {
            for path in stale {
                FMLiveness.record(path: path, state: .dead, source: .availability,
                                  error: availability.detail, now: now)
            }
            return FMLiveness.current(now: now)
        }
        // ② 落ちているブレーカは、それ自体が「直前に連続して失敗した」という観測
        if FMBreaker.isOpen {
            let previous = FMLiveness.read()
            for path in stale {
                // 直前の死のエラーを引き継ぐ。ここで nil にすると、ブレーカが落ちている間
                // 「死んでいる」だけが残って**なぜ死んだかが消える**
                FMLiveness.record(path: path, state: .dead, source: .breaker,
                                  error: previous?[path]?.error, now: now)
            }
            return FMLiveness.current(now: now)
        }
        // ③ 枠が空いているときだけ撃つ。取れたら必ず返す
        guard await FMLock.acquire(timeoutSeconds: probeLockTimeoutSeconds) else {
            return FMLiveness.current(now: now)
        }
        defer { FMLock.release() }
        for path in stale {
            _ = await probeOnce(path: path)
        }
        return FMLiveness.current(now: now)
    }

    /// 1経路を実際に呼んで台帳へ書く。**門を通らない**(呼び出し側が明示的に死活を知りたい
    /// ときの入口。`fleetest doctor` / `ft_doctor` はこちら)。返り値は書いた判定
    @discardableResult
    public static func probeOnce(path: FMLiveness.Path, now: Date = Date()) async -> FMLiveness.Verdict {
        let startedAt = Date()
        do {
            switch path {
            case .text:
                _ = try await LanguageModelSession().respond(
                    to: "Answer with just OK.",
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maxResponseTokens))
            case .vision:
                guard #available(macOS 27, *) else {
                    // 呼び出し側(refresh)は isSupported で弾いているので通らない。#available は
                    // Attachment に触るためにコンパイラが要求する分岐
                    let verdict = FMLiveness.Verdict(
                        state: .dead, checkedAt: now.timeIntervalSince1970,
                        source: .availability, error: FMVisionSupport.requirement)
                    return verdict
                }
                _ = try await LanguageModelSession().respond(
                    generating: FMLoadGenerator.LoadVisionVerdict.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 16)
                ) {
                    "Is this image a single solid color?"
                    Attachment(FMLoadGenerator.probeImage)
                }
            }
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            FMBreaker.recordSuccess()
            FMLiveness.record(path: path, state: .alive, source: .probe, ms: ms)
            return FMLiveness.Verdict(state: .alive, checkedAt: Date().timeIntervalSince1970,
                                      source: .probe, ms: ms)
        } catch {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            let message = FMHealth.describe(error)
            FMBreaker.recordFailure()
            FMLiveness.record(path: path, state: .dead, source: .probe, error: message, ms: ms)
            return FMLiveness.Verdict(state: .dead, checkedAt: Date().timeIntervalSince1970,
                                      source: .probe, error: message, ms: ms)
        }
    }
}
