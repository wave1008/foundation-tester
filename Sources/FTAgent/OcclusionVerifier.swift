// [PoC occlusion-guard] アクセシビリティツリー上は一致した要素が、実際の描画(スクショ)で
// 覆われ/切れ/減光されて「見えていない」偽陽性を、FM のマルチモーダル判定で排除する検証器。
// アサーション(exists/textEquals)がツリー通過した直後に1回だけ呼ぶ想定(常時実行はコスト過大)。
//
// 2アーム実装(PoC で正確性を比較するため):
//  - cropped: スクショを要素 frame(+padding)にクロップして FM に渡す。座標を言葉で説明する必要が
//    なく、視覚モデルが「この領域に期待テキストが明瞭に見えるか」だけに集中できる(本命)。
//  - full:    スクショ全体+frame 座標を言葉で渡す。座標→ピクセルの対応を FM に委ねるため弱いはず。
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

    // MARK: Arm B(本命): frame をクロップして判定

    public func verifyCropped(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async -> Result? {
        guard let full = Self.cgImage(fromPNG: screenshotPNG) else { return nil }
        // スクショの実ピクセルと frame 座標系のスケール差を吸収(iOS スクショは Retina で pt≠px)。
        let scaleX = CGFloat(full.width) / CGFloat(screen.width == 0 ? Double(full.width) : screen.width)
        let scaleY = CGFloat(full.height) / CGFloat(screen.height == 0 ? Double(full.height) : screen.height)
        let px = CGRect(x: CGFloat(frame.x) * scaleX - cropPadding,
                        y: CGFloat(frame.y) * scaleY - cropPadding,
                        width: CGFloat(frame.width) * scaleX + cropPadding * 2,
                        height: CGFloat(frame.height) * scaleY + cropPadding * 2)
        let clamped = px.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
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

    // MARK: Arm A(比較用): 全画面+座標を言葉で渡す

    public func verifyFull(expectedText: String, frame: FTRect, screen: FTRect,
                           screenshotPNG: Data) async -> Result? {
        guard let full = Self.cgImage(fromPNG: screenshotPNG) else { return nil }
        let instructions = """
        あなたは UI テストの視覚検証者です。スクリーンショット(=実際の描画)だけを根拠に、
        アクセシビリティツリーが報告する要素が、指定領域に覆われず・切れず・減光されず
        明瞭に描画されているかを厳密に判定してください。ツリーが存在を主張しても、視覚的に
        読めなければ visible=false としてください。推測で補完しないこと。
        """
        return await respond(instructions: instructions, image: full) {
            """
            アクセシビリティツリーは、次のテキストが以下の矩形に存在すると報告しています。
            期待テキスト: "\(expectedText)"
            報告領域(左上原点): x=\(Int(frame.x)) y=\(Int(frame.y)) 幅=\(Int(frame.width)) 高さ=\(Int(frame.height))
            画面サイズ: 幅=\(Int(screen.width)) 高さ=\(Int(screen.height))
            この領域に、そのテキストが覆われず・切れず・明瞭に描画されているか判定してください。
            """
        }
    }

    // MARK: - 共通の FM 呼び出し

    private func respond(instructions: String, image: CGImage,
                         prompt: () -> String) async -> Result? {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let verdict = try await session.respond(
                generating: VisibilityVerdict.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)
            ) {
                prompt()
                Attachment(image)
            }.content
            return Result(visible: verdict.visible, state: Self.name(verdict.state),
                          observedText: String(verdict.observedText.prefix(120)),
                          reason: String(verdict.reason.prefix(200)))
        } catch {
            return nil
        }
    }

    static func name(_ s: VisibilityState) -> String {
        switch s {
        case .fullyVisible: return "fullyVisible"
        case .covered: return "covered"
        case .dimmed: return "dimmed"
        case .notRendered: return "notRendered"
        case .textMismatch: return "textMismatch"
        }
    }

    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
