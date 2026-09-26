// occlusion-guard: FM が判定を返さなかったとき(macOS 26 で画像を渡せない・実呼び出しの失敗・
// 直列化待ちの期限切れ・陽性対照の注入)の代替判定。使う材料は同じ呼び出しの中で Tier-2 の近道が
// **既に読んだ** OCR の行(lines)と、Tier-1 のインク量だけ —— 追加の OCR は撃たない
// (近道が撃たれていない回は lines = nil = 判定不能。「読んで何も無かった」[] と混ぜると、読んでいない
// のにインク量だけで不可視と言う —— E2E の暖機前のステップで実際に出た)。
//
// **不可視なら FM の反転と同じく赤**(警告の段階で E2E とコーパスの誤った赤 0 を確かめてから上げた。
// 実測は docs/poc-fm-occlusion-guard.md §5.19)。**FM の反転と同じく、スクショが古い絵のままだと赤になる**
// (モニターの配信が張られた Android Emulator で実際に出た)—— OCR 固有の問題ではない。

import Foundation

public enum OCROnlyVisibility {
    public enum Outcome: Sendable, Equatable {
        case visible(TranscriptMatch.State)
        case notVisible(TranscriptMatch.State)
        /// 読める行が無く、インク量からも判定できない(画像不正 / 何か描かれてはいるが読めない
        /// = WebView・図形等)
        case undetermined
    }

    /// FM が判定を返さない run の occlusion-guard を説明する但し書き(括弧つき・先頭空白つき)。CLI の警告・
    /// FMHealth・doctor・ft_status が共有する。**ocrTextOcclusionCheck を知らない呼び手でも真になる形**
    /// (off なら読みが無く judge は常に判定不能 = 素通り)
    public static let fmFallbackCaveat =
        " (text that OCR cannot judge passes unchecked; with ocrTextOcclusionCheck off the guard passes through)"

    /// FM の判定と OCR の読みの判定の突き合わせ。**見えていると読めた側を採る**(赤は両方が見えないと
    /// 言った回か、OCR が判定不能で FM が見えないと言った回だけ)。どちらも期待文字列を知らずに読んだ文字を
    /// 同じ `TranscriptMatch` で照合するので「読めた」は描かれている直接の証拠で、「読めなかった」は読み手の
    /// 失敗でも起きる。割れた回は `disagreement` の注記で残す(率で監査する)。根拠は poc §5.22
    public static func merge(fmVisible: Bool, fmState: TranscriptMatch.State?,
                             ocr: Outcome) -> (visible: Bool, state: TranscriptMatch.State?, disagreement: StepNote?) {
        switch ocr {
        case .visible(let state) where !fmVisible:
            return (true, state, .ocrReadWhatFMMissed)
        case .notVisible where fmVisible:
            return (true, fmState, .fmReadWhatOCRMissed)
        default:
            return (fmVisible, fmState, nil)
        }
    }

    /// `lines` が nil(読んでいない)なら判定不能。空でなければ `TranscriptMatch.judge` へそのまま回す。
    /// 空なら `inkStdDev` で「描かれていない」か「判定不能」かだけを分ける。
    public static func judge(lines: [String]?, expected: String,
                             inkStdDev: Double?, inkThreshold: Double) -> Outcome {
        guard let lines else { return .undetermined }
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
