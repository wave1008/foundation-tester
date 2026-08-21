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

/// `systemAlertHandler`(DSL)の登録1件。2つの形を取る:
///
/// - `systemAlertHandler("許可")`(素のラベル)= **次に出たアラートがどれでも**このボタンを押す
/// - `systemAlertHandler(alert: "トラッキング", button: "許可")` = **題名がこの文字列を含む
///   アラート**にだけこのボタンを押す
///
/// どちらも**1回の登録 = 1枚のアラートの予告**で、押せたら台帳から外れる
/// (`SystemAlertWatchlist`)。同じアラートを2枚待つなら2回登録する。
/// 台帳が空の間は監視そのものが走らない = 判定の往復(約 73ms/ステップ)を払わない。
///
/// **題名は部分一致・ボタンは完全一致**。題名にはアプリ名が埋め込まれる
/// (「“ローソン.stub”が…トラッキングすることを…」)ので完全一致は書けない。
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

/// `systemAlertHandler` の登録と発火をまとめて持つ台帳。
/// StepExecutor はこれを1つ持つだけで、登録の列・除去・監視判定を個別に持たない。
///
/// **1回の登録 = 1枚のアラートの予告**。押せたら外れる。台帳が**空なら監視しない**
/// = 判定の往復を1回も払わない。シナリオの書き手はアラートが出る操作の**前に**登録し、
/// 同じアラートを2枚待つなら2回登録する —— `許可` のような汎用ラベルを複数のアラートが
/// 使う場合も、登録が枚数ぶんあるので取り合いにならない。
///
/// 値型で実装する(状態を共有する必要が無く、持ち主は StepExecutor の1箇所だけ)。
/// 寿命は StepExecutor と同じ = シナリオ1本。`setUp()` に書けば各 @Test の前に登録される
public struct SystemAlertWatchlist: Sendable {
    private var watches: [SystemAlertRule]

    public init(rules: [SystemAlertRule] = []) {
        watches = rules
    }

    /// 登録(DSL の `systemAlertHandler` から。宣言順を保って末尾へ足す)
    public mutating func register(_ rule: SystemAlertRule) {
        watches.append(rule)
    }

    /// まだ見張る必要があるか。**空 = 監視しない**(判定の往復を払わない)
    public var isWatching: Bool { !watches.isEmpty }

    /// この木で押すべきボタン(登録順・先に成立したもの)。除去はしない ——
    /// タップは失敗し得るので、**押せたと確定してから** `notePressed` で外す
    public func buttonToTap(in elements: [ElementInfo]) -> (button: ElementInfo, index: Int)? {
        SystemAlertDismissal.ruleToApply(in: elements, rules: watches)
            .map { ($0.button, $0.ruleIndex) }
    }

    /// 押せたことを記録し、**その登録を台帳から外す**(発火して不要になった)。
    /// 同じアラートがもう1枚来る前提は残らない —— 待つなら書き手がもう1回登録する
    public mutating func notePressed(_ index: Int) {
        guard watches.indices.contains(index) else { return }
        watches.remove(at: index)
    }

    /// 失敗メッセージ用の表示形(登録順)
    public var describedRules: [String] { watches.map { $0.described } }
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

    /// 登録の列から押すべきボタンを1つ選ぶ(登録された順・先に成立したものを採る)。
    /// 名指し形は**アラートの題名が読めて、部分一致するときだけ**成立する ——
    /// 題名が読めないアラートに名指しを当てると、意図しないアラートを閉じ得る
    public static func ruleToApply(in elements: [ElementInfo], rules: [SystemAlertRule])
        -> (button: ElementInfo, ruleIndex: Int)? {
        guard !rules.isEmpty else { return nil }
        let title = elements.first { $0.type == "alert" }?.label
        for (index, rule) in rules.enumerated() {
            switch rule {
            case .button(let label):
                if let hit = buttonToTap(in: elements, labels: [label]) { return (hit, index) }
            case .alert(let titleContains, let button):
                guard let title, title.contains(titleContains) else { continue }
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
            return "pressed \"\(label)\" on a system alert (systemAlertHandler)"
        }
        return "pressed \"\(label)\" on the system alert \"\(title)\" (systemAlertHandler)"
    }
}
