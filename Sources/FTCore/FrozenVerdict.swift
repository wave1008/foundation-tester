// 「デバイスの画面が凍結しているか」の判定と、その根拠を1箇所に置く。
//
// **この型が唯一の定義元**。run 前トリアージ(BlankWorkerTriage)・デバイスモニター
// (ApiMonitorCommand)は自前の真偽値を持たず、ここが返す `FrozenVerdict` を配る。
// 別々に持つと同じデバイスについて答えが食い違う —— 2026-08-11 に実際に起きた:
// run は「9台が凍結」と言って回復まで実行したのに、モニターの `Frozen:` は 0 のままだった。
// 判定の共有は docs/design.md の「判定は MCP と DSL で共有する」と同じ規律。
//
// **判定材料は一様フレーム(uniformBlank)**。拍動(noPresent)は付随する根拠にとどめる ——
// 本物の wedge でも拍動は回り続けることを実験で確かめた(2026-08-11)ので、**否定材料には
// 使えない**。偽陽性(アプリの初回描画待ち)との区別は**観測窓の長さ**で行う。
// 根拠を列挙して束ねる形なので、証拠の追加は enum の1ケースで済む。

import Foundation

/// 凍結の**根拠**。1つでも `isConclusive` な根拠があれば凍結と断じる。
public enum FrozenEvidence: String, Codable, Sendable, CaseIterable {
    /// 画面が一様(白/黒ベタ)。iOS・Android とも実測済みの型
    case uniformBlank
    /// 描画拍動(iOS=CADisplayLink / Android=Choreographer)の tick が止まっている。
    /// **これは「表示が進んだか」ではない**(2026-08-11 に実験で反証): 本物の wedge を故意に
    /// 起こして観測したところ、画面が完全に固まっていても拍動は 0.001〜0.016s で回り続けた。
    /// 測っているのは「アプリが vsync を要求し続けているか」で、コンポジタが wedge しても
    /// コールバックは来る。**凍結の否定には使えない**(生きていても凍結でありうる)。
    /// 止まっている場合は異常だが、それが表示の停止かアプリのハングかは分けられないので
    /// 単独では確定させない
    case noPresent
    /// 入力が届かない。能動プローブなので受動監視では撃てず、run 前トリアージ専用
    case inputNotLanding
    /// 陽性対照の注入(`FrozenInjection`)。検知経路を端から端まで通すためだけに使う
    case injected

    /// **単独で凍結と断じてよい根拠か**。`noPresent` だけ false
    /// (拍動の停止は異常だが、表示の停止とアプリのハングを分けられない)
    public var isConclusive: Bool { self != .noPresent }

    /// ログ・UI に出す短い語(rawValue はケース名なので人が読む面には出さない)
    public var label: String {
        switch self {
        case .uniformBlank: return "uniform-blank"
        case .noPresent: return "no-present"
        case .inputNotLanding: return "input-not-landing"
        case .injected: return "injected"
        }
    }
}

/// 凍結の判定結果。根拠の集合そのもので、真偽値は導出値として持つ。
///
/// `evidence` は**配列**(Set ではない): JSON へ書くとき並びが安定しないと、同じ状態の
/// 書き込みが毎回別バイトになり差分監視・テストが揺れる。`init` で重複除去と整列を行う。
public struct FrozenVerdict: Codable, Sendable, Equatable {
    public let evidence: [FrozenEvidence]

    public init(_ evidence: [FrozenEvidence]) {
        // CaseIterable の宣言順で整列する(rawValue の辞書順ではない = 追加時に並びが動かない)
        let unique = Set(evidence)
        self.evidence = FrozenEvidence.allCases.filter(unique.contains)
    }

    /// 根拠なし = 健全
    public static let healthy = FrozenVerdict([])

    /// **確定**。表示・除外・回復のトリガに使ってよい
    public var isFrozen: Bool { evidence.contains(where: \.isConclusive) }

    /// 根拠は1つ以上あるが確定はしていない(= 警告だけ出す状態)
    public var isSuspected: Bool { !evidence.isEmpty && !isFrozen }

    /// **注入だけが根拠 = 実体は健全**。公表(表示)はするが、回復・除外といった
    /// デバイスを触る動作は撃たない。陽性対照は「検知と配信の経路」を通したいのであって、
    /// シミュレータを実際に再起動したいわけではない
    public var isInjectedOnly: Bool { evidence == [.injected] }

    /// 別の観測者が出した判定と併合する。根拠は足し合わせるだけ
    /// (どれか1つでも確定なら確定 = 観測者ごとに強弱を付けない)
    public func merged(with other: FrozenVerdict) -> FrozenVerdict {
        FrozenVerdict(evidence + other.evidence)
    }

    /// 人が読む1行("uniform-blank, injected")。根拠が無いときは空文字
    public var summary: String {
        evidence.map(\.label).joined(separator: ", ")
    }

    // MARK: - 観測から判定を組み立てる(run 前トリアージとモニターの共通規則)

    /// 「描画が止まった」と見なす拍動の空き(秒)。**この1箇所だけが定義元**
    /// (run とモニターで別々に持つと、同じ機の判定が食い違う)。
    ///
    /// **5秒は余裕を見た値**: 拍動はアプリのメインスレッド上の CADisplayLink / Choreographer なので、
    /// メインスレッドが長時間ふさがると tick が飢えて「止まった」ように見える。実測では
    /// Flutter がまさに初回描画中の瞬間でも idle は 0.03〜0.10s しかなかったので、
    /// 5秒を超えるのは通常の処理では起きない
    public static let displayIdleFrozenThreshold: Double = 5.0

    /// 凍結と数えるか。
    ///
    /// **拍動を否定材料に使ってはいけない**(2026-08-11 の実験で反証): 本物の wedge でも
    /// 拍動は回り続ける(実測 0.001〜0.016s)。一度は「拍動が生きていれば凍結ではない」と
    /// したが、それでは**本物を1件も検出できない**。
    ///
    /// 偽陽性(アプリの初回描画待ち)と本物の違いは**時間**にある —— 描画待ちは数秒で解消し、
    /// wedge はいつまでも解消しない。判定材料は一様フレームのままにして、
    /// **観測窓を延ばす**ことで分ける(`BlankWorkerTriage.samples` / `intervalMs`)。
    public static func countsAsFrozen(uniformBlank: Bool, displayIdleSeconds: Double? = nil,
                                      threshold: Double = displayIdleFrozenThreshold) -> Bool {
        uniformBlank
    }

    /// 1台ぶんの観測から判定を組み立てる。**run 前トリアージもモニターもここを通す**。
    /// 拍動の停止は付随する根拠として残す(単独では確定しない)
    public static func observe(uniformBlank: Bool, displayIdleSeconds: Double?,
                               injected: Bool = false,
                               threshold: Double = displayIdleFrozenThreshold) -> FrozenVerdict {
        if injected { return FrozenVerdict([.injected]) }
        var evidence: [FrozenEvidence] = []
        if uniformBlank { evidence.append(.uniformBlank) }
        if let idle = displayIdleSeconds, idle > threshold { evidence.append(.noPresent) }
        return FrozenVerdict(evidence)
    }
}

/// **陽性対照の注入口**。
///
/// 凍結は意図的に起こせないので、これが無いと検知の**陽性側を一度も通せない**。
/// 2026-08-11 にモニターの凍結カウンタが「恒久 false」のままマージされた真因がこれで、
/// 当時の検証(実デバイスで10台に frozen が乗り誤検知 0)は**常に false を返す検出器が出す
/// 観測と完全に同一**だった。以後は注入 → run とモニターの双方が凍結と言う → 解除、までを
/// 常設テストで毎回通す。
///
/// **共有の観測層に置く**のが要点 —— run 前トリアージとモニターが同じ注入を見るので、
/// 「片方だけ凍結と言う」状態を陽性対照そのもので検出できる。
public enum FrozenInjection {
    /// デバイスキー(iOS=シミュレータ UDID / Android=adb serial)をカンマ区切りで並べる。
    /// 例: `FT_FAKE_FROZEN_KEYS=E38DCA93-...,emulator-5554`
    public static let environmentKey = "FT_FAKE_FROZEN_KEYS"

    public static func keys(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<String> {
        guard let raw = environment[environmentKey] else { return [] }
        return Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// key が nil のとき(キーを持たない対象)は**注入しない**。
    /// 「全部凍結」の暴発を防ぐため、必ず明示のキー一致だけで効かせる
    public static func isInjected(
        key: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let key, !key.isEmpty else { return false }
        return keys(environment: environment).contains(key)
    }
}
