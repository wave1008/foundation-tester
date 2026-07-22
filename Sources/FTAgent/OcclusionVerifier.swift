// occlusion-guard: アクセシビリティツリー上は一致した要素が、実際の描画(スクショ)で
// 覆われ/切れ/減光されて「見えていない」偽陽性を、FM のマルチモーダル判定で排除する検証器。
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
    @Guide(description: "期待テキストが覆われず・切れず・減光されず明瞭に読めるなら true。少しでも隠れ/欠け/判読困難があれば false")
    var visible: Bool

    @Guide(description: "見え方の分類")
    var state: VisibilityState

    @Guide(description: "実際に読み取れた文字列。読めなければ空文字")
    var observedText: String

    @Guide(description: "判定理由(日本語で1文)")
    var reason: String
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

    // frame をクロップして判定

    public func verifyCropped(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async -> Result? {
        guard let full = Self.cgImage(fromPNG: screenshotPNG) else { return nil }
        guard let clamped = Self.cropRect(frame: frame, screen: screen,
                                          imageWidth: full.width, imageHeight: full.height,
                                          cropPadding: cropPadding),
              let crop = full.cropping(to: clamped) else { return nil }

        let instructions = """
        あなたは UI テストの視覚検証者です。渡される画像は、ある UI 要素の周辺だけを切り出したものです。
        目的は「その要素が別の要素・オーバーレイ・ローディング表示・減光レイヤーに覆われて見えないか」
        (occlusion)だけを見抜くことです。次を厳守してください:
        - テキストは末尾が「…」で省略されたり、途中で折り返し(改行)されることがあります。
          省略・折り返しは正常であり visible=true とします。期待テキストの先頭部分が読めれば十分です。
        - visible=false にするのは次の場合だけ: (a)領域が別の不透明要素/オーバーレイに覆われている、
          (b)真っ白/真っ黒/単色で文字が全く無い、(c)期待テキストとは無関係の別文字列だけが描かれている。
        - 多少の減光でも判読できるなら visible=true。推測で補完しないこと。
        """
        return await respond(instructions: instructions, image: crop) {
            "期待テキスト(末尾は省略や折り返しがあり得る): \"\(expectedText)\"\nこのテキスト(またはその先頭部分)が、覆われず判読できる状態で描画されていますか。"
        }
    }

    // MARK: - 共通の FM 呼び出し

    private func respond(instructions: String, image: CGImage,
                         prompt: () -> String) async -> Result? {
        let session = LanguageModelSession(instructions: instructions)
        let startedAt = Date()
        do {
            let verdict = try await session.respond(
                generating: VisibilityVerdict.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)
            ) {
                prompt()
                Attachment(image)
            }.content
            FMHealth.record(kind: "occlusion", ms: Self.elapsedMs(startedAt), ok: true)
            return Result(visible: verdict.visible, state: Self.name(verdict.state),
                          observedText: String(verdict.observedText.prefix(120)),
                          reason: String(verdict.reason.prefix(200)))
        } catch {
            // nil を返すと呼び出し側(StepExecutor.occlusionFlip)はガードを素通りさせる。
            // 記録しないと「FM 全滅で無効」と「疑わしい要素が無く正常」が区別できない
            FMHealth.record(kind: "occlusion", ms: Self.elapsedMs(startedAt), ok: false,
                            error: "occlusion: \(error)")
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

    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
