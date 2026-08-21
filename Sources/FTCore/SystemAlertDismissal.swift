// iOS のシステム許可アラート(位置情報・通知など)を自動で押すときの「どれを押すか」。
//
// **ツールは推測しない**(2026-08-19)。位置情報の許可は「1回だけ許可 / Appの使用中は許可 /
// 許可しない」のように**どれが是認かが文脈で変わる**うえ、並び順もラベルもロケールと OS 版で
// 変わる。既定ボタンを当てにいくと、取り違えたときの症状が「テストが意図しない権限状態で
// 走り続ける」= 沈黙になる。だから押してよいラベルは**登録(iosAlertHandler)された分だけ**
// とし、登録が無ければ何もしない(従来どおりシナリオが自分で閉じる)。
//
// 「自動許可」も「自動拒否」もこの1つの仕組みで書ける ——
// 並べるラベルを是認側にするか拒否側にするかの違いしかない。

import Foundation

/// `iosAlertHandler`(DSL)の登録1件 = **1枚のアラートの予告**。
/// `alert`(どのアラートか)は必須 —— ボタンのラベルだけでは「なんのウィンドウの
/// 許可ボタンか」が読めず、無関係のアラート(別アプリの許可要求が前面に出る形)を
/// 押し得る。押せたら台帳から外れる(`SystemAlertWatchlist`)。
/// 同じアラートを2枚待つなら2回登録する。台帳が空の間は監視そのものが走らない
/// = 判定の往復(約 73ms/ステップ)を払わない。
///
/// **`alert` も `button` もセレクタと同じ記法**: `||` で候補を並べ(日英両対応)、
/// `*` で一致方法を選ぶ(bare = 完全一致 / `x*` = 前方 / `*x` = 後方 / `*x*` = 部分)。
///
///     alert: "*トラッキング*||*track your activity*", button: "許可||Allow"
///
/// 題名にはアプリ名が埋め込まれる(「“ローソン.stub”が…トラッキングすることを…」)ので、
/// 実用上 alert は `*x*` で書くことになる。button の bare = 完全一致は
/// `"許可"` が「許可しない」を押す事故を防ぐ —— `*許可*` と書けば部分一致になるが、
/// その危険も含めて書き手の選択になる(セレクタと同じ)
public struct SystemAlertRule: Sendable, Equatable {
    /// アラートの題名に当てるパターン
    public let alert: String
    /// 押すボタンのラベルに当てるパターン
    public let button: String

    public init(alert: String, button: String) {
        self.alert = alert
        self.button = button
    }

    /// 失敗メッセージ・ログ用の表示形
    public var described: String { "\(alert)→\(button)" }
}

/// `iosAlertHandler` の登録と発火をまとめて持つ台帳。
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

    /// 登録(DSL の `iosAlertHandler` から。宣言順を保って末尾へ足す)
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
    /// セレクタの `||` 記法を候補の列に割る(`"許可||Allow"` → `["許可", "Allow"]`)。
    /// 空の分岐(`"a||"` の末尾など)は落とす —— 空文字は `*` の解釈で「常に一致」に
    /// 化け得るので、書き間違いを黙って通さない
    static func alternatives(_ pattern: String) -> [String] {
        pattern.components(separatedBy: "||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 分岐1つが値に当たるか。**`*` の解釈はセレクタと同一**(`FTSelector.partialMatch` の
    /// 4形: bare = 完全一致 / `x*` = 前方 / `*x` = 後方 / `*x*` = 部分)。
    /// 判定も `FlowMatchMode.matches` を使う = セレクタと同じ正規化で比較する。
    /// `"*"` 単体が全一致に化けないのは partialMatch の性質(リテラル `*` の完全一致になる)
    static func branchMatches(_ branch: String, value: String?) -> Bool {
        let parsed = FTSelector.partialMatch(branch)
        return parsed.mode.matches(value, parsed.text)
    }

    /// パターン(`||` 分岐 + `*`)が値に当たるか
    static func patternMatches(_ pattern: String, value: String?) -> Bool {
        alternatives(pattern).contains { branchMatches($0, value: value) }
    }

    /// 登録の列から押すべきボタンを1つ選ぶ(登録された順・先に成立したものを採る)。
    /// **題名が読めるアラート**にだけ当てる(題名が読めないアラートに当てると意図しない
    /// アラートを閉じ得る)。押すボタンは**題名が一致したアラートの枠の中**から選ぶ ——
    /// アラートが重なっているとき(位置情報の直後に ATT など)、木の全ボタンから選ぶと
    /// 「題名は A に一致したのに B のボタンを押す」= `alert:` を必須にした意味が消える
    public static func ruleToApply(in elements: [ElementInfo], rules: [SystemAlertRule])
        -> (button: ElementInfo, ruleIndex: Int)? {
        guard !rules.isEmpty else { return nil }
        let alerts = elements.filter { $0.type == "alert" && !($0.label ?? "").isEmpty }
        guard !alerts.isEmpty else { return nil }
        for (index, rule) in rules.enumerated() {
            for alert in alerts where patternMatches(rule.alert, value: alert.label) {
                let scoped = elements.filter { alert.frame.contains($0.frame) }
                if let hit = buttonToTap(in: scoped, pattern: rule.button) { return (hit, index) }
            }
        }
        return nil
    }

    /// パターン(`||` 分岐 + `*`)で押すボタンを1つ選ぶ。分岐の順に試し、先に当たったものを
    /// 採る(「Appの使用中は許可」を「許可」より前に置けば、両方あるときは前者)。
    ///
    /// 型は `button`・enabled だけが対象。別の型で出るアラートでは**発火しない**が、
    /// 縮退の向きはそれでよい(押さなければシナリオが失敗して気付ける。押し間違えると
    /// 気付けない)。bare の分岐が完全一致なのも同じ理由(`"許可"` が「許可しない」を押さない)
    public static func buttonToTap(in elements: [ElementInfo], pattern: String) -> ElementInfo? {
        let candidates = elements.filter { $0.enabled && $0.type == "button" }
        for branch in alternatives(pattern) {
            if let hit = candidates.first(where: { branchMatches(branch, value: $0.label) }) {
                return hit
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
            return "pressed \"\(label)\" on a system alert (iosAlertHandler)"
        }
        return "pressed \"\(label)\" on the system alert \"\(title)\" (iosAlertHandler)"
    }
}
