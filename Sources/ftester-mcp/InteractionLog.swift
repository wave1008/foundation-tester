// 探索中の操作を「シナリオへ落とせる形」で覚えておく(ft_draft_scenario の材料)。
//
// **なぜ要るか**: MCP の目的は「デバイスを操作しながら実セレクタを採り、Swift DSL の
// シナリオへ落とす」こと。ところが操作の系列はどこにも残らず、12 手ほど動かしても
// シナリオは会話履歴から人手で組み直すしかなかった(2026-08-09 の実測)。
//
// **記録するのは FlowStep**(自前の DTO を作らない): 生成器 `ScenarioCodeGen.render` は
// Flow/FlowStep を受けるので、ここで別の形に貯めると写像を2箇所に持つことになる。
// セレクタが決まらなかった手も**落とさずに**残し、生成時に TODO コメントへ回す
// —— 黙って消すと、出来上がったシナリオが実際の手順と食い違う。
//
// 保持はメモリだけ(プロセスが落ちたら消えてよい。永続化は範囲外)。

import Foundation
import FTCore

struct InteractionLog {

    /// 1手ぶん。`step` が nil = セレクタを解決できず DSL の行にできなかった手
    struct Entry {
        /// 生成に使える形(セレクタ解決済み)。nil なら TODO 行になる
        var step: FlowStep?
        /// TODO 行に残す説明(何を撃ったか。ref と frame を含める)
        var unresolved: String?
        /// ft_launch の位置を覚えて「直近の launch 以降」を既定範囲にする
        var isLaunch: Bool = false
        /// @TestClass(app:) に使う bundleID(launch のときだけ)
        var bundleID: String?
        /// @TestClass(platform:) に使う
        var platform: String?
    }

    private(set) var entries: [Entry] = []

    /// 記録の上限。**古いほうから捨てる** —— 長い探索でメモリを食い続けないための安全弁で、
    /// 捨てたことは draft 側が言う
    static let maximumEntries = 500

    private(set) var droppedFromFront = 0

    mutating func record(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst()
            droppedFromFront += 1
        }
    }

    mutating func clear() {
        entries = []
        droppedFromFront = 0
    }

    /// 既定の範囲 = **直近の ft_launch 以降**(F-3)。launch が無ければ全体
    var sinceLastLaunch: [Entry] {
        guard let index = entries.lastIndex(where: \.isLaunch) else { return entries }
        return Array(entries[index...])
    }

    /// 生成対象のアプリ/プラットフォーム。範囲内の launch から採り、無ければ全体の最後から
    func target(in scope: [Entry]) -> (app: String, platform: String?) {
        let fromScope = scope.last { $0.bundleID != nil }
        let fallback = entries.last { $0.bundleID != nil }
        let chosen = fromScope ?? fallback
        return (chosen?.bundleID ?? "", chosen?.platform)
    }
}
