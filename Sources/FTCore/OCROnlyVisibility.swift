// occlusion-guard: FM が判定を返さなかったとき(macOS 26 で画像を渡せない・実呼び出しの失敗・
// 直列化待ちの期限切れ・陽性対照の注入)の代替判定。使う材料は同じ呼び出しの中で Tier-2 の近道が
// **既に読んだ** OCR の行(lines)と、Tier-1 のインク量だけ —— 追加の OCR は撃たない
// (近道が撃たれていない回は lines が空のまま渡ってくる)。
//
// **不可視と判定しても今は赤にしない**(呼び手が `.ocrOnlyWouldFlip` を残して素通りする)。
// 新しい検知は警告から入れる規律(ユーザー決定)で、デバイス実行で誤検知 0 を確かめてから赤へ上げる。
// コーパスでの実測(見えている実 crop 290 件で誤った赤 0)は docs/poc-fm-occlusion-guard.md §5.19。

import Foundation

public enum OCROnlyVisibility {
    public enum Outcome: Sendable, Equatable {
        case visible(TranscriptMatch.State)
        case notVisible(TranscriptMatch.State)
        /// 読める行が無く、インク量からも判定できない(画像不正 / 何か描かれてはいるが読めない
        /// = WebView・図形等)
        case undetermined
    }

    /// `lines` が空でなければ `TranscriptMatch.judge` へそのまま回す。空なら `inkStdDev` で
    /// 「描かれていない」か「判定不能」かだけを分ける(丸ごと読めた/一部読めたの判定はできない)。
    public static func judge(lines: [String], expected: String,
                             inkStdDev: Double?, inkThreshold: Double) -> Outcome {
        if !lines.isEmpty {
            let verdict = TranscriptMatch.judge(transcript: lines.joined(separator: " "), expected: expected)
            return verdict.visible ? .visible(verdict.state) : .notVisible(verdict.state)
        }
        // **occlusionInkThreshold をそのまま流用する**(専用の定数を置かない)。根拠: 実 crop
        // 290 件 + 合成で、この閾値を 6〜20 のどこに置いても結果は同一(空白は 0 付近・文字は
        // 40 以上に分かれ、間に境界例が無い。docs/poc-fm-occlusion-guard.md §5.19)
        guard let inkStdDev else { return .undetermined }
        return inkStdDev < inkThreshold ? .notVisible(.notRendered) : .undetermined
    }
}

/// **陽性対照の注入口**。FM の実際の不調(モデル不可用・ブレーカ開)は意図的に起こせないので、
/// これが無いと「FM が答えを返さなかった」経路を一度も通せない。デバイスを触る動作は何もしない
/// (`FrozenInjection` と同じ規律 —— 観測・分岐だけを差し替える)。
public enum FMNoVerdictInjection {
    public static let environmentKey = "FT_FAKE_FM_NO_VERDICT"

    public static func isActive(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }
}
