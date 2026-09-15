import Foundation

/// **FM ヒールの陽性対照の注入口**(`FrozenInjection` と同じ規律の保守者専用口)。
///
/// 採用門は FM の自己申告 confidence == "high" だが、実測で1度も開かない(日英 272 件で high 0 件・
/// E2E の `90_自己修復` は 9/2 以降すべて `heal-proposal-rejected`)。門の手前(FM の提案)は結果に
/// 残るが、**門の先(採用 → ヒールキャッシュ → 修正提案 → 2周目のキャッシュ通過)はデバイスで
/// 1度も通らない**。この口は門だけを開け、提案そのもの(FM が選んだ要素)は本物のまま使う ——
/// 選択が誤っていれば後段の検証(`90_自己修復` の `tapped=v2`)が落ちる。
///
/// - 効くのは `.proposed` の採否だけ(`.noReplacement` / `.unresolved` は変えない)
/// - 門を注入で開けたステップには `StepNote.healConfidenceInjected` を必ず立て、修正提案・
///   ヒールキャッシュの rationale にも印を残す(キャッシュは run を跨いで残るため)
/// - 受け手向けの口にしない(docs/user-docs に書かない)。利用口は `Scripts/fm-verify.sh`
/// - シナリオ実行プロセスは環境を継ぐので `FT_FAKE_HEAL_CONFIDENCE_HIGH=1 fleetest run …` で届く。
///   **ssh は運ばない**(`--runner` 越しには効かない)
public enum HealConfidenceInjection {
    public static let environmentKey = "FT_FAKE_HEAL_CONFIDENCE_HIGH"

    /// 値が `1` のときだけ効かせる(`0`・空・その他は無効 = 暴発させない)
    public static func isActive(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }
}
