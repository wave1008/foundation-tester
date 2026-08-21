// iOS のシステム許可アラート(位置情報・通知など)を自動で押すときの「どれを押すか」。
//
// **ツールは推測しない**(2026-08-19)。位置情報の許可は「1回だけ許可 / Appの使用中は許可 /
// 許可しない」のように**どれが是認かが文脈で変わる**うえ、並び順もラベルもロケールと OS 版で
// 変わる。既定ボタンを当てにいくと、取り違えたときの症状が「テストが意図しない権限状態で
// 走り続ける」= 沈黙になる。だから押してよいラベルは**実行プロファイルに書かれた分だけ**
// とし、書かれていなければ何もしない(従来どおりシナリオが自分で閉じる)。
//
// 「自動許可」も「自動拒否」もこの1つの仕組みで書ける ——
// 並べるラベルを是認側にするか拒否側にするかの違いしかない。

import Foundation

/// 実行プロファイル `iosSystemAlertButtons` の1エントリ。2つの形を取る:
///
/// - `"許可"`(素のラベル)= **どのアラートに出ても押してよい**。監視は解除されない
///   (どんなアラートが何回来るかを言っていないので、解除の根拠が無い)
/// - `{"alert": "トラッキング", "button": "許可"}` = **題名がこの文字列を含むアラート**にだけ
///   このボタンを押す。**処理したら消費**され、名指しの宣言を全部処理し終えたら
///   (素のラベルが無ければ)監視そのものを解除する = 以後1往復も払わない。
///   「宣言したアラートを処理したら監視を解除する」(ユーザー決定 2026-08-21)は
///   この形でだけ成立する —— 解除には「待っているアラートの集合」が要り、
///   ラベルの列はそれを言えない(`許可` は複数のアラートが共有する。2026-08-22 の実害)
///
/// **題名は部分一致・ボタンは完全一致**。題名にはアプリ名が埋め込まれる
/// (「“サンプル.stub”が…トラッキングすることを…」)ので完全一致は書けない。
/// ボタンの完全一致は従来どおり(`"許可"` が「許可しない」を押す事故を防ぐ)
public enum SystemAlertRule: Sendable, Equatable {
    case button(String)
    case alert(titleContains: String, button: String)

    /// 押すボタンのラベル
    public var buttonLabel: String {
        switch self {
        case .button(let label): return label
        case .alert(_, let button): return button
        }
    }

    /// 失敗メッセージ・ログ用の表示形
    public var described: String {
        switch self {
        case .button(let label): return label
        case .alert(let title, let button): return "\(title)→\(button)"
        }
    }
}

extension SystemAlertRule: Codable {
    private enum ObjectKeys: String, CodingKey { case alert, button }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let label = try? single.decode(String.self) {
            self = .button(label)
            return
        }
        let object = try decoder.container(keyedBy: ObjectKeys.self)
        self = .alert(titleContains: try object.decode(String.self, forKey: .alert),
                      button: try object.decode(String.self, forKey: .button))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .button(let label):
            var single = encoder.singleValueContainer()
            try single.encode(label)
        case .alert(let title, let button):
            var object = encoder.container(keyedBy: ObjectKeys.self)
            try object.encode(title, forKey: .alert)
            try object.encode(button, forKey: .button)
        }
    }
}

/// `iosSystemAlertButtons` の宣言と**その消費状態**をまとめて持つ台帳。
/// StepExecutor はこれを1つ持つだけで、規則の列・消費済み集合・監視判定・
/// 「名指しだけ消費する」という知識を個別に持たない(2026-08-22 ユーザー提案で集約)。
///
/// 値型で実装する(状態を共有する必要が無く、持ち主は StepExecutor の1箇所だけ)。
/// 寿命は StepExecutor と同じ = シナリオ1本。次のシナリオでは作り直されて消費が戻る
public struct SystemAlertWatchlist: Sendable {
    /// 宣言1つと、その消費状態
    private struct Watch {
        let rule: SystemAlertRule
        var handled = false
        /// まだ見張る理由になるか。**素のラベルは常に true**(どのアラートが何回来るかを
        /// 言っていない = やめてよい根拠が無い)。名指しは処理するまで
        var isActive: Bool {
            switch rule {
            case .button: return true
            case .alert: return !handled
            }
        }
    }

    private var watches: [Watch]

    public init(rules: [SystemAlertRule]) {
        watches = rules.map { Watch(rule: $0) }
    }

    /// まだ見張る必要があるか。false = 監視を解除してよい(判定の往復を払わない)。
    /// 名指しだけの宣言を全部処理し終えたときだけ false になる
    public var isWatching: Bool { watches.contains { $0.isActive } }

    /// この木で押すべきボタン(宣言順・先に成立したもの)。消費はしない ——
    /// タップは失敗し得るので、**押せたと確定してから** `notePressed` で記録する
    public func buttonToTap(in elements: [ElementInfo]) -> (button: ElementInfo, index: Int)? {
        SystemAlertDismissal.ruleToApply(
            in: elements, rules: watches.map { $0.rule },
            handled: Set(watches.indices.filter { watches[$0].handled }))
            .map { ($0.button, $0.ruleIndex) }
    }

    /// 押せたことを記録する。**消費されるのは名指し(`.alert`)だけ** —— 素のラベルは
    /// 汎用の文言(`許可`)を複数のアラートが共有するので、使い切る扱いにできない
    /// (2026-08-22 の実害)。この分岐を呼び手に持たせないことがこの型の存在理由
    public mutating func notePressed(_ index: Int) {
        guard watches.indices.contains(index) else { return }
        if case .alert = watches[index].rule { watches[index].handled = true }
    }

    /// 失敗メッセージ用の表示形(宣言順)
    public var describedRules: [String] { watches.map { $0.rule.described } }
}

public enum SystemAlertDismissal {
    /// fallback(SpringBoard 参照セッション)の木から押すべきボタンを1つ選ぶ。
    /// labels は実行プロファイルに書かれた順で、**先に見つかったものを採る**
    /// (「Appの使用中は許可」を「許可」より前に置けば、両方あるときは前者が選ばれる)。
    ///
    /// **完全一致だけ**。部分一致にすると `"許可"` の指定が **"許可しない" を押す** ——
    /// 自動化が正反対の権限を与える形の事故になり、しかも run は緑のまま進む。
    ///
    /// 型は `button` に限る。別の型で出るアラートでは**発火しない**が、
    /// 縮退の向きはそれでよい(押さなければ従来どおりシナリオが失敗して気付ける。
    /// 押し間違えると気付けない)。
    public static func buttonToTap(in elements: [ElementInfo], labels: [String]) -> ElementInfo? {
        guard !labels.isEmpty else { return nil }
        let candidates = elements.filter { $0.enabled && $0.type == "button" }
        for label in labels {
            let wanted = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty else { continue }
            if let hit = candidates.first(where: { $0.label == wanted }) { return hit }
        }
        return nil
    }

    /// 規則の列から押すべきボタンを1つ選ぶ(宣言された順・先に成立したものを採る)。
    /// `handled` は消費済みの規則の添字(名指し形だけが入る)。
    /// 名指し形は**アラートの題名が読めて、部分一致するときだけ**成立する ——
    /// 題名が読めないアラートに名指しを当てると、意図しないアラートを閉じ得る
    public static func ruleToApply(in elements: [ElementInfo], rules: [SystemAlertRule],
                                   handled: Set<Int>) -> (button: ElementInfo, ruleIndex: Int)? {
        guard !rules.isEmpty else { return nil }
        let title = elements.first { $0.type == "alert" }?.label
        for (index, rule) in rules.enumerated() {
            switch rule {
            case .button(let label):
                if let hit = buttonToTap(in: elements, labels: [label]) { return (hit, index) }
            case .alert(let titleContains, let button):
                guard !handled.contains(index),
                      let title, title.contains(titleContains) else { continue }
                if let hit = buttonToTap(in: elements, labels: [button]) { return (hit, index) }
            }
        }
        return nil
    }

    /// 押したことを run ログへ残す文言。**記録が無いのは沈黙**である ——
    /// 権限という後に響く状態を自動で変えている以上、「何を押したか」はレポートから
    /// 読めなければならない。受け手報告(2026-08-20): テスト対象アプリの前面に
    /// **マップの**許可アラートが出た = 一覧のラベルが一致すれば**無関係のアプリの権限を
    /// 自動で許可し得る**。ラベルの選び方(推測しない)は誤爆の確率を下げるだけで、
    /// 誤爆したときに気付ける保証は別に要る
    public static func actionDescription(pressed button: ElementInfo,
                                         in elements: [ElementInfo]) -> String {
        let label = button.label ?? "(no label)"
        guard let title = elements.first(where: { $0.type == "alert" })?.label,
              !title.isEmpty else {
            return "pressed \"\(label)\" on a system alert (iosSystemAlertButtons)"
        }
        return "pressed \"\(label)\" on the system alert \"\(title)\" (iosSystemAlertButtons)"
    }
}
