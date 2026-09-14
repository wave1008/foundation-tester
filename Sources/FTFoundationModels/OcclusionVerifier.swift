// occlusion-guard: アクセシビリティツリー上は一致した要素が、実際の描画(スクショ)で
// 覆われ/切れ/減光されて「見えていない」誤った緑を、FM のマルチモーダル判定で排除する検証器。
// アサーション(exists/textEquals)がツリー通過した直後に呼ぶ(poll-until-visible で待機中は各周回)。
// スクショを要素 frame(+padding)にクロップして FM に渡す(座標を言葉で説明せず、その領域だけを
// 見せる)。全画面+座標を言葉で渡す方式は PoC で精度が劣ると確定し不採用(docs/poc-fm-occlusion-guard.md §5.10)。
// frame の単位はスクショのピクセル空間に一致している前提(呼び出し側で pt→px 換算する)。
//
// **FM には期待文字列を渡さない**。訊くのは「何が描かれているか」(転写)だけで、可否は
// `FTCore.TranscriptMatch` が期待文字列と突き合わせて決める。期待文字列を渡して可否を訊く形は、
// 空白・別の文字の crop でも期待文字列を observedText に写して visible=true と答えた(おうむ返し。
// 実測は TranscriptMatch 冒頭)。**prompt にも instructions にも期待文字列を入れないこと** ——
// `OcclusionTranscriptTests` がソース走査で守る。

import CoreGraphics
import Foundation
import FoundationModels
import FTCore
import ImageIO
import UniformTypeIdentifiers

// MARK: - @Generable 転写型

/// FM に求める出力は転写 1 欄だけ。可否・分類の欄を置くと、読む前に結論を書き、転写がその結論に
/// 合わせて期待文字列を写す形になる(欄順を転写 → 可否に替えても直らなかった。2026-09-15 実測)
@Generable
struct DrawnTextTranscript {
    @Guide(description: "Every character of text drawn in the image, transcribed exactly as written, in reading order; empty when the image contains no legible text")
    var text: String
}

// MARK: - 検証器

public struct OcclusionVerifier {
    /// FTCore(FM 非依存)へ返す平坦な結果。
    public struct Result: Sendable {
        public let visible: Bool
        /// fullyVisible / covered / notRendered / textMismatch(TranscriptMatch.State)
        public let state: String
        public let observedText: String
        public let reason: String
    }

    /// クロップ時に要素 frame の周囲へ足す余白(px)。覆いの縁・近傍の文脈を FM に見せる。
    public var cropPadding: CGFloat

    public init(cropPadding: CGFloat = 24) {
        self.cropPadding = cropPadding
    }

    /// 転写の出力上限トークン。**転写は期待文字列の先頭が読めれば足りる**(TranscriptMatch は
    /// 切り詰めを認める)ので、上限で切れても判定は変わらない。コーパスの最長ラベル(説明文 60 字前後)が
    /// 途中で切れない程度として 120
    static let transcriptResponseTokens = 120

    /// 等倍で期待文字列を読めなかったときに拡大して読み直す倍率。OCR のはしご(RegionText.upscaleLadder)と
    /// 同じく、拡大は画素を増やすだけで文字を作らないので、覆い・空白の crop は拡大しても空のまま =
    /// 見逃しは増えない。等倍で 1 文字誤読した小さな文字を救う(実測は TranscriptMatch 冒頭)
    static let enlargedRetryFactor = 2

    /// 暖機(`prewarmVisibilityCheck`)の殺しスイッチ。`FT_FM_OCCLUSION_PREWARM=0` で撃たない
    static func prewarmEnabled(environment: [String: String]) -> Bool {
        environment["FT_FM_OCCLUSION_PREWARM"] != "0"
    }

    /// 転写の instructions。**暖機したセッションと本番の呼び出しで同一の文字列**でなければ意味がない
    /// (instructions が違えば prefill も別物)ので、ここ1箇所に置く
    static let instructions = """
    You read text in screenshots of mobile apps for automated tests. The image is a crop around
    one UI element. Transcribe only the text that is actually drawn, exactly as written, in reading
    order. Never guess, complete or translate. If the area is blank, a solid colour, or covered by
    an opaque layer with no text, return an empty transcript.
    """

    /// プロンプト本文。期待文字列を含めない(定数であることが、含めていないことの証明)
    static let prompt = "What text is drawn in this image?"

    // frame をクロップして判定

    public func verifyCropped(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async -> Result? {
        guard let full = Self.cgImage(fromPNG: screenshotPNG) else { return nil }
        guard let clamped = OcclusionCrop.rect(frame: frame, screen: screen,
                                               imageWidth: full.width, imageHeight: full.height,
                                               cropPadding: cropPadding),
              let crop = full.cropping(to: clamped) else { return nil }
        // Attachment(画像入力)は macOS 27+。26 では判定不能(nil)= ガードは素通り。
        // 通常は StepExecutor.occlusionFlip が FMVisionSupport で手前で止めるので、ここは保険
        guard #available(macOS 27, *) else { return nil }
        // FM はホスト全体で直列化される資源。並列に投げても速くならず modelmanagerd の
        // モデル積み降ろしだけが増えるので、呼び出し側で待ち行列を作る(FMLock 参照)。
        // 等倍と拡大の 2 回は**同じ FMGate の取得の中**で回す(間に他ワーカーを割り込ませない)
        guard await FMGate.enter() else { return nil }
        defer { FMGate.leave() }

        guard let first = await Self.transcribe(crop, instructions: Self.instructions, prewarmed: true)
        else { return nil }
        var verdict = TranscriptMatch.judge(transcript: first, expected: expectedText)
        var observed = first
        if !verdict.visible {
            // 等倍で読めなかった回だけ拡大して読み直す。読めれば見えている(誤った赤を作らない側)。
            // 読めなくても判定は等倍と同じ向き(空・別の文字)なので、reason は拡大側の転写で作る
            let enlarged = RegionText.enlarged(crop, by: Self.enlargedRetryFactor)
            if enlarged !== crop,
               let second = await Self.transcribe(enlarged, instructions: Self.instructions, prewarmed: false) {
                let retried = TranscriptMatch.judge(transcript: second, expected: expectedText)
                if retried.visible || second.count > first.count {
                    verdict = retried
                    observed = second
                }
            }
        }
        var reason = verdict.reason
        // 反転(不可視判定)したときだけ、**FM が実際に見た crop** を保存する。
        // レポートの失敗時スクショは poll が尽きた後の別撮りで、FM の入力ではない。
        // これを残さないと「FM の誤判定」なのか「渡した crop が別物だった」のかを
        // 事後に切り分けられない(2026-07-23、切り分け不能に陥って追加)。
        if !verdict.visible, let dumpedPath = Self.dump(crop: crop, expectedText: expectedText) {
            reason += " [crop: \(dumpedPath)]"
        }
        return Result(visible: verdict.visible, state: verdict.state.rawValue,
                      observedText: String(observed.prefix(120)), reason: reason)
    }

    // MARK: - FM 呼び出し(転写)

    /// nil = FM の失敗(呼び出し側はガードを素通りさせる。記録しないと「FM 全滅で無効」と
    /// 「疑わしい要素が無く正常」が区別できないので、成功も失敗も FMHealth へ計上する)
    @available(macOS 27, *)
    private static func transcribe(_ image: CGImage, instructions: String, prewarmed: Bool) async -> String? {
        // 暖機済みがあれば使う(無ければその場で作る = 従来と同じ)。
        // **取り出したら捨てる** —— respond を通したセッションは会話履歴を持つので使い回せない
        let session = (prewarmed ? OcclusionPrewarm.take(matching: instructions) : nil)
            ?? LanguageModelSession(instructions: instructions)
        let startedAt = Date()
        do {
            let transcript = try await session.respond(
                generating: DrawnTextTranscript.self,
                options: GenerationOptions(samplingMode: .greedy,
                                           maximumResponseTokens: Self.transcriptResponseTokens)
            ) {
                Self.prompt
                Attachment(image)
            }.content
            FMHealth.record(kind: "occlusion", path: .vision, ms: Self.elapsedMs(startedAt), ok: true)
            return transcript.text
        } catch {
            FMHealth.record(kind: "occlusion", path: .vision, ms: Self.elapsedMs(startedAt), ok: false,
                            error: "occlusion: \(FMHealth.describe(error))")
            return nil
        }
    }

    static func elapsedMs(_ from: Date) -> Double { Date().timeIntervalSince(from) * 1000 }

    /// FM が不可視と判定した crop を ~/Library/Logs/fleetest/occlusion/ へ保存する
    /// (環境変数 FT_OCCLUSION_DUMP_DIR で変更可、"off" で無効)。
    /// 保存した PNG は Scripts/occlusion-repro.swift にそのまま食わせて再判定できる。
    /// 真の陽性(実際に覆われている過渡状態)でも保存されるため、7日より古いものは書き込み時に掃除する。
    static func dump(crop: CGImage, expectedText: String) -> String? {
        let env = ProcessInfo.processInfo.environment["FT_OCCLUSION_DUMP_DIR"]
        if env == "off" { return nil }
        let dir = env.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/fleetest/occlusion")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pruneOldDumps(in: dir)
        // FM はホスト全体で直列化(約1回/秒)されるが並列ワーカーで同秒が起き得るため ms まで入れる
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("occlusion-\(stamp).png")
        guard let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, crop, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        // 期待テキストが無いと再判定できないので隣に置く
        try? expectedText.write(to: url.deletingPathExtension().appendingPathExtension("txt"),
                                atomically: true, encoding: .utf8)
        return url.path
    }

    private static func pruneOldDumps(in dir: URL) {
        // 消すのは自分が書いた occlusion-<時刻>.png/.txt だけ(置き場は環境変数で差し替えられる)
        DumpRetention.prune(in: dir, prefix: "occlusion-", extensions: ["png", "txt"])
    }

    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
