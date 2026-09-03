// occlusion-guard: アクセシビリティツリー上は一致した要素が、実際の描画(スクショ)で
// 覆われ/切れ/減光されて「見えていない」誤った緑を、FM のマルチモーダル判定で排除する検証器。
// アサーション(exists/textEquals)がツリー通過した直後に呼ぶ(poll-until-visible で待機中は各周回)。
// スクショを要素 frame(+padding)にクロップして FM に渡す(座標を言葉で説明せず「この領域に期待
// テキストが明瞭に見えるか」だけに集中させる)。全画面+座標を言葉で渡す方式は PoC で精度が劣ると
// 確定し不採用(経緯は docs/poc-fm-occlusion-guard.md §5.10)。
// frame の単位はスクショのピクセル空間に一致している前提(呼び出し側で pt→px 換算する)。

import CoreGraphics
import Foundation
import FoundationModels
import FTCore
import ImageIO
import UniformTypeIdentifiers

// MARK: - @Generable 判定型

@Generable
enum VisibilityState {
    case fullyVisible   // 覆われず・切れず・明瞭に読める
    case covered        // 別要素/オーバーレイに重なって見えない
    case dimmed         // 薄い/ぼけて判読困難
    case notRendered    // その位置に該当テキストが描かれていない
    case textMismatch   // 別の文字列が描かれている
}

@Generable
struct VisibilityVerdict {
    @Guide(description: "true when the expected text is clearly readable — not covered, not cut off, not dimmed. false on any occlusion, clipping or illegibility")
    var visible: Bool

    @Guide(description: "Classification of how it appears")
    var state: VisibilityState

    @Guide(description: "The text actually read; empty when unreadable")
    var observedText: String

    @Guide(description: "Reason for the verdict, in one English sentence")
    var reason: String
}

/// 1段目(選別)の出力。**`reason` だけを落とした VisibilityVerdict**。
/// reason は一文まるごと生成するので占める時間が大きく、しかも**反転した回しか読まれない**
/// (StepExecutor+Assert.swift の `if v.visible { return nil }`)。
/// **`observedText` は残す** —— 落とすとモデルが「文字を読んで期待値と突き合わせる」工程ごと
/// やめてしまい、判定が壊れる(実データで 106/147 が反転を取りこぼした。
/// docs/performance-tuning.md §3.5.1)。`visible` が先頭でも**スキーマ本文はプロンプトに入る**
/// ので、欄の増減は判定に効く = 変えたら必ずコーパスで照合すること。
@Generable
struct VisibilityScreening {
    @Guide(description: "true when the expected text is clearly readable — not covered, not cut off, not dimmed. false on any occlusion, clipping or illegibility")
    var visible: Bool

    @Guide(description: "Classification of how it appears")
    var state: VisibilityState

    @Guide(description: "The text actually read; empty when unreadable")
    var observedText: String
}

// MARK: - 検証器

public struct OcclusionVerifier {
    /// FTCore(FM 非依存)へ返す平坦な結果。
    public struct Result: Sendable {
        public let visible: Bool
        /// fullyVisible / covered / dimmed / notRendered / textMismatch
        public let state: String
        public let observedText: String
        public let reason: String
    }

    /// クロップ時に要素 frame の周囲へ足す余白(px)。覆いの縁・近傍の文脈を FM に見せる。
    public var cropPadding: CGFloat

    public init(cropPadding: CGFloat = 24) {
        self.cropPadding = cropPadding
    }

    /// 1段目(選別)の出力上限トークン。reason(一文)が無いぶん 200 は要らない。
    /// 2026-09-03 実測(M1Max): 反転済み crop 147 枚で **med 1878→1257ms(−33%)**、
    /// 生きた画面から採った陽性 crop 62 枚で 2401→1970ms(−18%)。
    /// **判定は 209/209 で従来と一致**(visible も state も)
    static let screeningResponseTokens = 80

    /// 2段目(反転の説明)の出力上限トークン。**従来の1回呼び出しと同じ値**を保つ ——
    /// 反転の判定・文言・crop 保存はこの呼び出しが行うので、変えると反転の挙動が変わる
    static let detailResponseTokens = 200

    /// 2段化の殺しスイッチ。`FT_FM_OCCLUSION_TWO_STAGE=0` で従来の1回呼び出しへ戻す(A/B 用)
    static func twoStageEnabled(environment: [String: String]) -> Bool {
        environment["FT_FM_OCCLUSION_TWO_STAGE"] != "0"
    }

    // frame をクロップして判定

    public func verifyCropped(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async -> Result? {
        guard let full = Self.cgImage(fromPNG: screenshotPNG) else { return nil }
        guard let clamped = Self.cropRect(frame: frame, screen: screen,
                                          imageWidth: full.width, imageHeight: full.height,
                                          cropPadding: cropPadding),
              let crop = full.cropping(to: clamped) else { return nil }

        let instructions = """
        You visually verify UI tests. The image you receive is a crop around one UI element.
        Your only job is to detect occlusion: whether the element is hidden behind another
        element, an overlay, a loading indicator or a dimming layer. Follow these rules strictly:
        - Text may be truncated with an ellipsis or wrapped onto multiple lines. Truncation and
          wrapping are normal — return visible=true. Reading the beginning of the expected text is enough.
        - Return visible=false ONLY when: (a) the area is covered by another opaque element/overlay,
          (b) it is blank/black/solid-colour with no text at all, or (c) only unrelated text is drawn.
        - Slight dimming is visible=true as long as the text is legible. Never fill gaps by guessing.
        """
        return await respond(instructions: instructions, image: crop, expectedText: expectedText) {
            "Expected text (may be truncated or wrapped at the end): \"\(expectedText)\"\nIs this text (or its beginning) drawn unoccluded and legible?"
        }
    }

    // MARK: - 共通の FM 呼び出し

    private func respond(instructions: String, image: CGImage, expectedText: String,
                         prompt: () -> String) async -> Result? {
        // Attachment(画像入力)は macOS 27+。26 では判定不能(nil)= ガードは素通り。
        // 通常は StepExecutor.occlusionFlip が FMVisionSupport で手前で止めるので、ここは保険
        guard #available(macOS 27, *) else { return nil }
        // FM はホスト全体で直列化される資源。並列に投げても速くならず modelmanagerd の
        // モデル積み降ろしだけが増えるので、呼び出し側で待ち行列を作る(FMLock 参照)
        guard await FMGate.enter() else { return nil }
        defer { FMGate.leave() }
        // **2段構え**。1段目は reason を作らせない選別(実測 −33%)。「見えている」と答えた回は
        // ここで終わる —— reason は反転した回しか読まれないので、95% 以上の回で一文まるごと
        // 生成していた時間が消える。**反転する回だけ2段目 = 従来と同じ呼び出し**を撃ち、
        // 判定・文言・crop の保存はそちらが行う(= 反転した回の挙動は変わらない)。
        // 1段目が反転を取りこぼす危険は実データで測ってある(反転済み crop 147 枚で 0 件・
        // 陽性 62 枚でも判定は全一致。docs/performance-tuning.md §3.5.1)。
        // 2回とも**同じ FMGate の取得の中**で回す(間に他ワーカーを割り込ませない。triage と同じ)。
        if Self.twoStageEnabled(environment: ProcessInfo.processInfo.environment) {
            let screeningStartedAt = Date()
            do {
                let screening = try await LanguageModelSession(instructions: instructions).respond(
                    generating: VisibilityScreening.self,
                    options: GenerationOptions(sampling: .greedy,
                                               maximumResponseTokens: Self.screeningResponseTokens)
                ) {
                    prompt()
                    Attachment(image)
                }.content
                FMHealth.record(kind: "occlusion", path: .vision, ms: Self.elapsedMs(screeningStartedAt), ok: true)
                if screening.visible {
                    // 見えている回は reason を誰も読まない(呼び出し側は visible で return する)
                    return Result(visible: true, state: Self.name(screening.state),
                                  observedText: String(screening.observedText.prefix(120)), reason: "")
                }
            } catch {
                // 従来の失敗と同じ扱い(nil = ガード素通り)。ここで2段目へ落とすと、FM が
                // 死んだホストで1回の判定に2回分の時間を捨てる
                FMHealth.record(kind: "occlusion", path: .vision, ms: Self.elapsedMs(screeningStartedAt), ok: false,
                                error: "occlusion(screening): \(FMHealth.describe(error))")
                return nil
            }
        }
        let session = LanguageModelSession(instructions: instructions)
        let startedAt = Date()
        do {
            let verdict = try await session.respond(
                generating: VisibilityVerdict.self,
                options: GenerationOptions(sampling: .greedy,
                                           maximumResponseTokens: Self.detailResponseTokens)
            ) {
                prompt()
                Attachment(image)
            }.content
            FMHealth.record(kind: "occlusion", path: .vision, ms: Self.elapsedMs(startedAt), ok: true)
            var reason = String(verdict.reason.prefix(200))
            // 反転(不可視判定)したときだけ、**FM が実際に見た crop** を保存する。
            // レポートの失敗時スクショは poll が尽きた後の別撮りで、FM の入力ではない。
            // これを残さないと「FM の誤判定」なのか「渡した crop が別物だった」のかを
            // 事後に切り分けられない(2026-07-23、切り分け不能に陥って追加)。
            if !verdict.visible, let dumpedPath = Self.dump(crop: image, expectedText: expectedText) {
                reason += " [crop: \(dumpedPath)]"
            }
            return Result(visible: verdict.visible, state: Self.name(verdict.state),
                          observedText: String(verdict.observedText.prefix(120)),
                          reason: reason)
        } catch {
            // nil を返すと呼び出し側(StepExecutor.occlusionFlip)はガードを素通りさせる。
            // 記録しないと「FM 全滅で無効」と「疑わしい要素が無く正常」が区別できない
            FMHealth.record(kind: "occlusion", path: .vision, ms: Self.elapsedMs(startedAt), ok: false,
                            error: "occlusion: \(FMHealth.describe(error))")
            return nil
        }
    }

    static func elapsedMs(_ from: Date) -> Double { Date().timeIntervalSince(from) * 1000 }

    static func name(_ s: VisibilityState) -> String {
        switch s {
        case .fullyVisible: return "fullyVisible"
        case .covered: return "covered"
        case .dimmed: return "dimmed"
        case .notRendered: return "notRendered"
        case .textMismatch: return "textMismatch"
        }
    }

    /// frame(pt)→スクショ(px)へ換算し、FM に渡すクロップ矩形(px・画像内にクランプ済み)を返す。
    /// nil = 換算後に有効領域が無い(退化 frame・画面外)。純幾何のためユニットテスト対象。
    ///
    /// 余白(cropPadding)は覆いの縁・近傍の文脈を FM に見せるためのものだが、固定値だと小要素
    /// (バッジ「3」・価格など)でクロップの過半を近傍が占め、FM が対象でなく近傍を見て誤反転する
    /// (実機で約50%誤反転の一因)。そこで **軸ごとに余白を要素サイズの 1/3 で頭打ち**にし、
    /// 対象がクロップの概ね 6 割以上を占めるようにする(大要素では従来どおり cropPadding で頭打ち)。
    static func cropRect(frame: FTRect, screen: FTRect, imageWidth: Int, imageHeight: Int,
                         cropPadding: CGFloat) -> CGRect? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let scaleX = CGFloat(imageWidth) / CGFloat(screen.width == 0 ? Double(imageWidth) : screen.width)
        let scaleY = CGFloat(imageHeight) / CGFloat(screen.height == 0 ? Double(imageHeight) : screen.height)
        let wpx = CGFloat(frame.width) * scaleX
        let hpx = CGFloat(frame.height) * scaleY
        // 対象がクロップの ≳60% を占めるよう、小要素では余白を要素サイズの 1/3 に比例縮小する。
        let padX = min(cropPadding, wpx / 3)
        let padY = min(cropPadding, hpx / 3)
        let px = CGRect(x: CGFloat(frame.x) * scaleX - padX,
                        y: CGFloat(frame.y) * scaleY - padY,
                        width: wpx + padX * 2,
                        height: hpx + padY * 2)
        let clamped = px.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }

    /// FM が不可視と判定した crop を ~/Library/Logs/fleetest/occlusion/ へ保存する
    /// (環境変数 FT_OCCLUSION_DUMP_DIR で変更可、"off" で無効)。
    /// 保存した PNG は Scripts/occlusion-repro.swift にそのまま食わせて再判定できる。
    /// 真の陽性(実際に覆われている過渡状態)でも保存されるため、7日より古いものは書き込み時に掃除する。
    static func dump(crop: CGImage, expectedText: String) -> String? {
        let env = ProcessInfo.processInfo.environment["FT_OCCLUSION_DUMP_DIR"]
        if env == "off" { return nil }
        let dir = env.map { URL(fileURLWithPath: $0) }
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
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for url in entries {
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, mtime < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
