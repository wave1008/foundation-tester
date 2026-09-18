// findImage / findImages(Shirates Vision の VisionDriveImageExtension)の照合の中核。
//
// Shirates と同じもの:
//   - テンプレート = DefaultClassifier の見本(`vision/classifiers/DefaultClassifier/` 以下)。
//     ラベル(親フォルダの相対パスを `_` でつないだもの)が**引数で終わる**フォルダの画像を使う
//     (VisionClassifierShard.getFiles)。`_binary.` の画像と `#` で始まるファイルは使わない
//   - 自 OS の印(`@i` / `@a`)が付いたテンプレートを先に試す(findImageCore)
//   - アスペクト比の許容幅の式と既定 0.2(SegmentContainer.filterByAspectRatio)・0 < 許容幅 ≤ 0.5
//   - 距離は Vision の画像特徴量(GenerateImageFeaturePrintRequest)の距離。既定の閾値 0.15
//     (Const.VISION_FIND_IMAGE_THRESHOLD)。findImage は `<=`・findImages は `<`(Shirates のまま)
//   - findImage は1位が閾値を超えたとき、1位の画像を DefaultClassifier に掛け、ラベルが一致し、かつ
//     確信度が閾値以下かそのラベルの見本との距離が閾値以下なら採る(VisionElement.classifyFull。
//     呼び手の StepExecutor.classificationConfirmed が行う。分類器は imageIs と共有)
// 違い:
//   - 候補の切り出しは画像の区分け(SegmentContainer)ではなく **a11y の要素の枠**。見本も同じ枠で
//     切ったもの(`fleetest vision capture`)を置くこと
//   - 許容幅に入る候補が無いとき、Shirates は区分けを全部残すが、こちらは候補なしにする
//     (a11y の木は数百要素あり、形の違う要素を全部特徴量に掛けると遅いうえ、特徴量は正方形へ
//     縮めて比べるので形の違う要素が閾値を割ることがある)
//   - 候補はアスペクト比がテンプレートに近い順に並べて比べ、距離が同じならその順を保つ

import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum FindImage {
    /// Shirates の Const.VISION_FIND_IMAGE_THRESHOLD(特徴量の距離。小さいほど似ている)
    public static let defaultThreshold = 0.15
    /// Shirates の Const.VISION_FIND_IMAGE_ASPECT_RATIO_TOLERANCE
    public static let defaultAspectRatioTolerance = 0.2
    /// DSL の findImage の `waitSeconds:` の既定(秒)。0 = 今の画面を1回だけ見る(Shirates の findImage の
    /// waitSeconds = 0.0 と同じ・ユーザー決定 2026-09-19)。1回 0.16〜0.25 秒かかるので、実行プロファイルの
    /// defaultTimeout(5 秒)まで撮り直すと「無いことを確かめる」たびに 5 秒を払う(docs/performance-tuning.md §3.30)。
    /// **待つのは検証の側**(existImage の既定は実行プロファイルの defaultTimeout)
    public static let defaultWaitSeconds: Double = 0

    public struct Match: Sendable {
        public let element: ElementInfo
        /// 画面に見えている部分の枠(タップ点と切り出しの元。画面外へはみ出した要素は画面で切る)
        public let visibleFrame: FTRect
        public let distance: Double
        public let template: URL
        /// シナリオに書けるセレクタ(`SelectorNaming`。書けなければ nil)。見つけた要素だけに付ける
        public var selector: String?
    }

    public enum MatchError: LocalizedError, CustomStringConvertible {
        case invalidTolerance(Double)
        case noTemplate(label: String, directory: String)
        case unreadableTemplate(String)
        /// Vision が異なる画像に同一の特徴量を返した(機械全体の一時的な異常。ANE / Vision の縮退)
        case degeneratePrints(template: String)

        public var description: String {
            switch self {
            case .invalidTolerance(let value):
                return "aspectRatioTolerance must be greater than 0 and at most 0.5 (got \(value))"
            case .noTemplate(let label, let directory):
                return "no template image for \"\(label)\": put a sample image in \(directory)/<folder ending with \(label)>/"
                    + " (capture one with `fleetest vision capture`)"
            case .unreadableTemplate(let path):
                return "the template image could not be read: \(path)"
            case .degeneratePrints(let template):
                return "Vision returned the same image feature print for different images (the template \(template)"
                    + " is at distance 0 from a blank image), so no image can be told apart right now;"
                    + " this is a transient state of the machine (retry the run; if it persists, reboot)"
                    + " unless the template itself is a blank image"
            }
        }
        public var errorDescription: String? { description }
    }

    /// 引数の検査(DSL がデバイスに触る前に落とすため public)。nil = 問題なし
    public static func validate(aspectRatioTolerance: Double) -> String? {
        aspectRatioTolerance > 0 && aspectRatioTolerance <= 0.5
            ? nil : MatchError.invalidTolerance(aspectRatioTolerance).description
    }

    // MARK: - テンプレート

    /// `label` で終わるラベルのフォルダの画像。自 OS の印(ファイル名かフォルダに `@i` / `@a`)を
    /// 持つものを先に、同じ組の中はパス順
    public static func templateFiles(label: String, classifierDirectory: URL, isAndroid: Bool) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: classifierDirectory, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return [] }
        let rootComponents = classifierDirectory.standardizedFileURL.pathComponents
        var files: [(url: URL, labelKey: String)] = []
        for case let file as URL in walker
        where VisionClassifier.imageExtensions.contains(file.pathExtension.lowercased())
            && !file.lastPathComponent.hasPrefix("#")
            && !file.lastPathComponent.contains("_binary.") {
            let parent = file.deletingLastPathComponent().standardizedFileURL.pathComponents
            guard parent.count > rootComponents.count else { continue }
            let key = parent.dropFirst(rootComponents.count).joined(separator: "_")
            if key.hasSuffix(label) { files.append((file, key)) }
        }
        let annotation = isAndroid ? "@a" : "@i"
        func forThisPlatform(_ entry: (url: URL, labelKey: String)) -> Bool {
            entry.url.lastPathComponent.contains(annotation)
                || entry.labelKey.split(separator: "_").contains { $0.hasPrefix(annotation) }
        }
        let sorted = files.sorted { $0.url.path < $1.url.path }
        return (sorted.filter(forThisPlatform) + sorted.filter { !forThisPlatform($0) }).map(\.url)
    }

    // MARK: - 候補

    /// Shirates の filterByAspectRatio と同じ式(幅と高さを逆向きに ±許容幅 だけ振った比の範囲)
    public static func aspectRatioRange(width: Double, height: Double, tolerance: Double) -> ClosedRange<Double> {
        let r1 = width * (1 - tolerance) / (height * (1 + tolerance))
        let r2 = width * (1 + tolerance) / (height * (1 - tolerance))
        return min(r1, r2)...max(r1, r2)
    }

    /// 見えている枠のアスペクト比が許容幅に入る要素を、テンプレートに近い順に返す。
    /// 見えている枠が同じ要素(容器と中身が同じ大きさ)は1つに畳む —— 切り出す画像が同じなので
    /// 比べても同じ距離になる。残すのは id を持つもの、その中では木の順で先(= 外側)。
    /// **ラベルで選ばない**: XCUITest の木は `accessibilityHidden` の内側の Image も SF Symbol 名の id と
    /// ラベル付きで同じ枠に載せるので、ラベルを加点すると操作対象のボタン(id だけ)が飾りに負ける
    /// (2026-09-19 E2E-iOS の #radio_a が id=circle になった)
    public static func candidates(in elements: [ElementInfo], screen: FTRect,
                                  templateWidth: Double, templateHeight: Double,
                                  tolerance: Double) -> [(element: ElementInfo, visibleFrame: FTRect)] {
        guard templateWidth > 0, templateHeight > 0 else { return [] }
        let range = aspectRatioRange(width: templateWidth, height: templateHeight, tolerance: tolerance)
        let templateAspect = templateWidth / templateHeight
        var byFrame: [String: Int] = [:]
        var picked: [(element: ElementInfo, visibleFrame: FTRect, order: Int)] = []
        func hasID(_ e: ElementInfo) -> Bool { e.identifier?.isEmpty == false }
        for (order, element) in elements.enumerated() {
            guard let visible = ScrollGeometry.intersection(element.frame, screen),
                  visible.width > 0, visible.height > 0,
                  range.contains(visible.width / visible.height) else { continue }
            let frameKey = "\(visible.x),\(visible.y),\(visible.width),\(visible.height)"
            if let index = byFrame[frameKey] {
                if hasID(element), !hasID(picked[index].element) {
                    picked[index] = (element, visible, picked[index].order)
                }
                continue
            }
            byFrame[frameKey] = picked.count
            picked.append((element, visible, order))
        }
        func closeness(_ frame: FTRect) -> Double { abs(log((frame.width / frame.height) / templateAspect)) }
        return picked
            .sorted { lhs, rhs in
                let (a, b) = (closeness(lhs.visibleFrame), closeness(rhs.visibleFrame))
                return a != b ? a < b : lhs.order < rhs.order
            }
            .map { ($0.element, $0.visibleFrame) }
    }

    // MARK: - 特徴量

    public static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 画像の特徴量(Shirates の ImageFeaturePrintMatcher.getFeaturePrintObservation と同じ要求)。
    /// 1回ごとに VisionUsageLedger へ1件書く
    public static func featurePrint(_ image: CGImage) async throws -> FeaturePrintObservation {
        let start = Date()
        do {
            let observation = try await GenerateImageFeaturePrintRequest().perform(on: image)
            VisionUsageLedger.record(ok: true, ms: Date().timeIntervalSince(start) * 1000)
            return observation
        } catch {
            VisionUsageLedger.record(ok: false, ms: Date().timeIntervalSince(start) * 1000)
            throw error
        }
    }

    private static let templateLock = NSLock()
    nonisolated(unsafe) private static var templatePrints: [String: FeaturePrintObservation] = [:]

    static func forgetTemplatePrints() {
        templateLock.withLock { templatePrints = [:] }
    }

    /// テンプレートの特徴量(ファイルのパス・更新時刻・大きさが同じならプロセス内で使い回す)
    static func templatePrint(_ url: URL, image: CGImage) async throws -> FeaturePrintObservation {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.standardizedFileURL.path)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            + "|\(attributes?[.size] as? Int ?? 0)"
        if let cached = templateLock.withLock({ templatePrints[key] }) { return cached }
        let observation = try await featurePrint(image)
        templateLock.withLock { templatePrints[key] = observation }
        return observation
    }

    /// 縮退の検知に使う一様な白(この画像の特徴量は、実物の見本とは距離 1.4 ほど離れる。2026-09-19 実測)
    static let blankSentinel: CGImage = {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return context.makeImage()!
    }()

    /// **Vision が縮退していないか**。異なる画像の特徴量が距離 0 = 何を比べても 0 で、最初の候補を「発見」して
    /// 別の要素を叩く(2026-09-19 04:29〜04:32 に3 SUT の別プロセスで同時に起き、5分後には正常だった。
    /// 一様な白と実物の見本は 1.44 離れるので、0 は縮退か見本自体が白紙かのどちらか)。
    /// 判定は純粋関数(テストは同じ観測を2つ渡して破れることを確かめる)
    static func isDegenerate(templateDistanceToBlank distance: Double) -> Bool { distance == 0 }

    /// 1つのテンプレートを画面の候補と比べ、距離の小さい順に返す(閾値では絞らない)。
    /// **照合1回につき一様な白の特徴量を1つ作って縮退を確かめる**(候補ごとではない。約 4ms)。
    /// 縮退していたらテンプレートの控えも捨てる(縮退中に作った特徴量を次の回に使わない)
    public static func match(template: URL, elements: [ElementInfo], screen: FTRect, screenshot: CGImage,
                             tolerance: Double) async throws -> [Match] {
        guard let templateImage = loadImage(template) else {
            throw MatchError.unreadableTemplate(template.path)
        }
        let candidates = candidates(in: elements, screen: screen,
                                    templateWidth: Double(templateImage.width),
                                    templateHeight: Double(templateImage.height), tolerance: tolerance)
        guard !candidates.isEmpty else { return [] }
        let templateObservation = try await templatePrint(template, image: templateImage)
        let blank = try await featurePrint(blankSentinel)
        if isDegenerate(templateDistanceToBlank: try templateObservation.distance(to: blank)) {
            forgetTemplatePrints()
            throw MatchError.degeneratePrints(template: template.lastPathComponent)
        }
        var matches: [Match] = []
        for candidate in candidates {
            guard let crop = VisionClassifier.crop(image: screenshot, frame: candidate.visibleFrame, screen: screen)
            else { continue }
            let distance = try templateObservation.distance(to: try await featurePrint(crop))
            matches.append(Match(element: candidate.element, visibleFrame: candidate.visibleFrame,
                                 distance: distance, template: template))
        }
        // 安定ソート = 距離が同じならアスペクト比が近い順を保つ
        return matches.enumerated()
            .sorted { $0.element.distance != $1.element.distance
                ? $0.element.distance < $1.element.distance : $0.offset < $1.offset }
            .map(\.element)
    }
}
