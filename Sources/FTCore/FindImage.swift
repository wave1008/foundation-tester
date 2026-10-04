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
    /// waitSeconds = 0.0 と同じ・ユーザー決定)。1回 0.16〜0.25 秒かかるので、実行プロファイルの
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
        /// Vision が同じ画像に違う特徴量を返した(縮退ほど極端でない一時的な異常。距離が信用できない)
        case inconsistentPrints(template: String, distance: Double)
        /// アプリの領域が一色(`BlankFrameDetector.isUnjudgeable`)。比べると全候補が「似ていない」になり、
        /// 見つからない(`isEmpty` での否定なら誤った緑)と読んでしまうので照合しない
        case blankScreenshot
        /// 絵が木に追いついていない(前に検証が控えた絵と木に対して「木は変わったのに絵が同じ」か、前に古いと
        /// 判定した絵と同じ。`StaleFrameDetector`)。遷移前の絵で照合すると全候補が似ていない = 見つからない
        /// (`isEmpty` の否定なら誤った緑)ので照合しない
        case staleScreenshot

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
            case .inconsistentPrints(let template, let distance):
                return "Vision returned a different image feature print for the same image (the template \(template)"
                    + " re-measured at distance \(String(format: "%.4f", distance)) from its earlier print; a healthy"
                    + " machine returns exactly the same print), so image distances cannot be trusted right now;"
                    + " this is a transient state of the machine (retry the run; if it persists, reboot)"
            case .blankScreenshot:
                return "the app area of the screenshot is a single colour (nothing is drawn there, or the capture"
                    + " failed), so no image could be compared"
            case .staleScreenshot:
                return "the screenshot has not caught up with the screen (the tree changed but the picture did"
                    + " not), so no image could be compared"
            }
        }
        public var errorDescription: String? { description }

        /// Vision 自身の異常(縮退・測り直しの不一致)。一色の絵・古い絵は含まない(補助プロセスの救済の対象外)
        var isVisionAnomaly: Bool {
            switch self {
            case .degeneratePrints, .inconsistentPrints: return true
            default: return false
            }
        }

        var isStaleScreenshot: Bool { if case .staleScreenshot = self { return true } else { return false } }

        /// 待てば戻る状態(Vision の異常・一色の絵。`retryingTransientAnomalies` が待って走査をやり直す対象)
        var isTransient: Bool {
            switch self {
            case .degeneratePrints, .inconsistentPrints, .blankScreenshot, .staleScreenshot: return true
            case .invalidTolerance, .noTemplate, .unreadableTemplate: return false
            }
        }
    }

    /// 待ってもなお異常だった(文言に待った回数と秒を足す。元の文言はそのまま前に置く)
    public struct PersistentAnomaly: LocalizedError, CustomStringConvertible {
        public let last: MatchError
        public let retries: Int
        public let waitedSeconds: Double
        public var description: String {
            last.description + "; it was still so after re-measuring \(retries) times over"
                + " \(String(format: "%.1f", waitedSeconds)) seconds of waiting"
        }
        public var errorDescription: String? { description }
    }

    /// Vision の異常(縮退・測り直しの不一致)を検知したとき、走査をやり直す前に待つ秒数の列(合計 15.5 秒)。
    /// 実測(M2 Ultra・Android E2E 8 並列 + 配信 24fps): 異常は**そのプロセスで最初の照合でだけ**起き
    /// (2 回目以降の照合は 0/30)、すぐには戻らず数秒で戻る。0.2/0.5/1/2/4 秒の列で待つと、30 件のうち
    /// 1 回で 4・3 回で 16・5 回(計 7.7 秒)で 28 件が戻り、残り 2 件は約 9〜10 秒たっても異常のままだった
    /// (戻るまでの時間は 0.6〜9.2 秒・中央値 約 2.8 秒)。最後を 8 秒にして 10 秒超えの戻りまで拾う。
    /// **ふだんはシナリオ開始時の暖機(FindImage+Prewarm.swift)がこの時間を先に使い切る**ので、ここは暖機より先に
    /// 照合した回と暖機の後に崩れた回の砦。**待つのは異常を検知した走査だけ**(健全な走査の所要は変わらない)。待った時間は締め切りから差し引く
    /// (`DeadlineExclusion`。アプリの応答ではない)。尽きたら `PersistentAnomaly` で失敗(従来どおり赤)。
    /// **CPU で計算させる案は不採用**(同じ実測で異常 63% = 悪化・所要 2.5〜3 倍。壊れるのはモデルの手前の画像の変換)
    public static let anomalyRetryDelays: [Double] = [0.5, 1, 2, 4, 8]

    /// 絵が木に追いついていない(`MatchError.staleScreenshot`)ときに待つ秒数の列(計 7.5 秒)。**根拠**(実測・Android E2E
    /// 8 並列 + 配信 24fps): 追いついた回は中央値 1.5 秒・90% で 2.8 秒・最長 5.0 秒。その最長を覆う長さで打ち切る。
    /// **尽きたら失敗にせず、最新の絵で照合する**(古い絵の検知は照合を赤にしない = 新しい検知は警告から。CMP の iOS in-app で
    /// 20 秒以上同じ絵が返り続け、失敗にした版は緑だったシナリオを毎周赤にした)
    public static let staleRetryDelays: [Double] = [0.5, 1, 2, 4]

    /// `body`(1回の走査)を、待てば戻る Vision の異常のあいだ `delays` の順に待ってやり直す。
    /// 異常以外のエラーはそのまま投げる。`onRetry` は待つ直前に呼ぶ(何回目か・検知した異常)。純粋な制御だけ
    /// (待ち方は `sleep` で差し替える = テストは実時間を待たない)
    static func retryingTransientAnomalies<T>(delays: (MatchError) -> [Double],
                                              sleep: (Double) async throws -> Void,
                                              onRetry: (Int, MatchError) -> Void,
                                              _ body: () async throws -> T) async throws -> T {
        try await retryingTransientAnomalies(delays: delays, sleep: sleep, onRetry: onRetry,
                                             rescueSource: nil, onRescue: { _ in }) { _ in try await body() }
    }

    /// 補助プロセスの救済の結果(`onRescue` へ渡す)。**門で落ちた回は呼ばない**(既存の注記のまま待ち直しへ落ちる)
    enum RescueOutcome: Equatable { case rescued, unavailable }

    /// 上の版 + **最初の Vision の異常(`isVisionAnomaly`)の待ちの前に**、`rescueSource`(長寿命の補助プロセス)で同じ走査を
    /// 1 回だけやり直す。補助の値でも門(`match`)は同じに掛かるので、通れば結果を採って `.rescued`・
    /// 補助が無い・答えない・unhealthy(`VisionHelperError`)なら `.unavailable` で既存の待ち直しへ落ちる・
    /// 補助の値が門で落ちた(異常のまま)なら黙って既存の待ち直しへ落ちる。救済は走査につき 1 回
    /// (最初の失敗で打ち切る = 補助が刺さっていても余計に待たない)。`body` には計算元を渡す(平常時は `.inProcess`)
    static func retryingTransientAnomalies<T>(delays: (MatchError) -> [Double],
                                              sleep: (Double) async throws -> Void,
                                              onRetry: (Int, MatchError) -> Void,
                                              rescueSource: PrintSource?,
                                              onRescue: (RescueOutcome) -> Void,
                                              _ body: (PrintSource) async throws -> T) async throws -> T {
        var attempt = 0
        var waited = 0.0
        var rescueTried = false
        while true {
            do {
                return try await body(.inProcess)
            } catch let error as MatchError where error.isTransient {
                if !rescueTried, error.isVisionAnomaly, let rescueSource {
                    rescueTried = true
                    do {
                        let rescued = try await body(rescueSource)
                        onRescue(.rescued)
                        return rescued
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch is VisionHelperError {
                        onRescue(.unavailable)
                    } catch {
                        // 門で落ちた異常・一色や古い絵・設定の誤り: 既存の待ち直しがそのまま扱う
                    }
                }
                let schedule = delays(error)
                guard attempt < schedule.count else {
                    if attempt == 0 { throw error }
                    throw PersistentAnomaly(last: error, retries: attempt, waitedSeconds: waited)
                }
                onRetry(attempt + 1, error)
                try await sleep(schedule[attempt])
                waited += schedule[attempt]
                attempt += 1
            }
        }
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
    /// (E2E-iOS の #radio_a が id=circle になった実例がある)
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
        templateLock.withLock { featurePrintCount += 1 }
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
    /// 特徴量を作った回数(テスト用。回数だけが費用なので、門や控えの効き目を回数で縛る)
    nonisolated(unsafe) static var featurePrintCount = 0
    nonisolated(unsafe) private static var templatePrints: [String: FeaturePrintObservation] = [:]
    /// プロセス内の控えのうち、永続控え(TemplatePrintStore)に載っているもの(= 書き直さない)
    nonisolated(unsafe) private static var persistedTemplateKeys: Set<String> = []
    /// このプロセスで測り直して控えと一致した見本(= 以後の走査では「最初の見本」になったときだけ測り直す)
    nonisolated(unsafe) private static var verifiedTemplateKeys: Set<String> = []

    static func forgetTemplatePrints() {
        templateLock.withLock { templatePrints = [:]; persistedTemplateKeys = []; verifiedTemplateKeys = [] }
    }

    private static func memoryKey(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\(url.standardizedFileURL.path)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            + "|\(attributes?[.size] as? Int ?? 0)"
    }

    /// テンプレートの特徴量。プロセス内の控え(パス・更新時刻・大きさ)→ 永続控え(中身と OS の版が一致)→ 計算、の順。
    /// **計算したものは永続控えにまだ書かない**(書くのは match が門を通した後 = `persistTemplatePrint`)
    static func templatePrint(_ url: URL, image: CGImage,
                              source: PrintSource = .inProcess) async throws -> FeaturePrintObservation {
        let key = memoryKey(url)
        if let cached = templateLock.withLock({ templatePrints[key] }) { return cached }
        if let stored = TemplatePrintStore.lookup(url) {
            // 永続控えに載るのは門を通った特徴量だけ = 確かめ済みとして扱う(今の機械の状態は走査の最初の見本で見る)
            templateLock.withLock {
                templatePrints[key] = stored
                persistedTemplateKeys.insert(key)
                verifiedTemplateKeys.insert(key)
            }
            return stored
        }
        let observation = try await source.compute(image)
        templateLock.withLock { templatePrints[key] = observation }
        return observation
    }

    /// 門(縮退・測り直し)を通った見本の特徴量を永続控えへ書く(載っていれば何もしない)
    private static func persistTemplatePrint(_ url: URL, _ observation: FeaturePrintObservation) {
        let key = memoryKey(url)
        guard templateLock.withLock({ persistedTemplateKeys.insert(key).inserted }) else { return }
        TemplatePrintStore.record(url, print: observation)
    }

    /// 門で落ちた: プロセス内の控えを全部捨て、その見本の永続控えも消す(壊れた状態の特徴量を持ち越さない)
    private static func discardTemplatePrints(after template: URL) {
        forgetTemplatePrints()
        TemplatePrintStore.drop(template)
    }

    /// 縮退の検知に使う一様な白(この画像の特徴量は、実物の見本とは距離 1.4 ほど離れる。実測)
    static let blankSentinel: CGImage = {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return context.makeImage()!
    }()

    /// **Vision が縮退していないか**。異なる画像の特徴量が距離 0 = 何を比べても 0 で、最初の候補を「発見」して
    /// 別の要素を叩く(3 SUT の別プロセスで同時に起き、5分後には正常に戻った実測がある。
    /// 一様な白と実物の見本は 1.44 離れるので、0 は縮退か見本自体が白紙かのどちらか)。
    /// 判定は純粋関数(テストは同じ観測を2つ渡して破れることを確かめる)
    static func isDegenerate(templateDistanceToBlank distance: Double) -> Bool { distance == 0 }

    /// **同じ見本を取り直した特徴量が控えと一致するか**(縮退の門が拾えない「半端な異常」の門)。
    /// 健全なら完全に一致する(実測: 4 機 = M1 / M1 Max / M1 Ultra / M2 Ultra・macOS 27.0/27.2 で
    /// 見本 60 枚 × 5 回 × 4 = 1,200 回すべて距離 0)。許容幅 `selfDistanceTolerance` は、異なる見本どうしの
    /// 最小距離(0.0011。同じ実測)より一桁小さい値。超えたら照合の距離を信用しない
    /// (負荷テストでは普段 0.002 前後で見つかる見本が 0.33〜0.43 で「見つからない」になった = findImage の
    /// 誤った赤、`isEmpty` での否定なら誤った緑)。判定は純粋関数
    static let selfDistanceTolerance: Double = 0.0001
    static func isConsistent(selfDistance distance: Double) -> Bool { distance <= selfDistanceTolerance }

    /// findImages の結果: 全テンプレートの照合を合わせ、閾値未満(`<`。nil なら絞らない)だけを残し、
    /// **同じ要素(ref)は距離の小さいほうで1つに畳んで**距離順に返す(同じ距離なら先に出た順)。
    /// Shirates の findImages はテンプレートを1枚(getFile)しか使わないが、fleetest はラベルの見本を全部使う
    /// (docs/shirates-parity.md。OS の版・画面の倍率・部品の状態ごとの見本がどれか1枚に当たればよい)
    public static func mergeAcrossTemplates(_ perTemplate: [[Match]], threshold: Double?) -> [Match] {
        var best: [Int: (order: Int, match: Match)] = [:]
        var order = 0
        for match in perTemplate.joined() where threshold.map({ match.distance < $0 }) ?? true {
            if let current = best[match.element.ref] {
                if match.distance < current.match.distance { best[match.element.ref] = (current.order, match) }
            } else {
                best[match.element.ref] = (order, match)
                order += 1
            }
        }
        return best.values
            .sorted { $0.match.distance != $1.match.distance
                ? $0.match.distance < $1.match.distance : $0.order < $1.order }
            .map(\.match)
    }

    /// 1回の走査(同じスクリーンショット)の中で、候補の切り出しの特徴量を見本どうしで使い回す控え。
    /// 見本が N 枚あると候補の特徴量を N 回計算し直していた(findImages をラベルの見本全部に広げて
    /// 照合が約3倍になった実測)。鍵は見えている枠 = 同じスクリーンショットなら同じ切り出し。
    /// **走査ごとに作り直す**(別のスクリーンショットの特徴量で照合しない)
    public final class CandidatePrints: @unchecked Sendable {
        private var prints: [String: FeaturePrintObservation] = [:]
        /// 特徴量の計算元(この走査の見本・白紙・候補すべて。既定はこのプロセスの Vision)
        let source: PrintSource
        public init(source: PrintSource = .inProcess) { self.source = source }
        /// 実際に特徴量を計算した回数(控えから返した回は数えない)
        public private(set) var computed = 0
        /// 縮退の門の白紙の特徴量(走査で1回だけ作り、全見本の判定に使い回す)
        fileprivate var blank: FeaturePrintObservation?
        /// この走査で「今の機械の状態」を測り直し済みか(最初に照合した見本で1回)
        fileprivate var machineRechecked = false
        fileprivate func observation(for frame: FTRect, compute: () async throws -> FeaturePrintObservation?)
            async rethrows -> FeaturePrintObservation? {
            let key = "\(frame.x),\(frame.y),\(frame.width),\(frame.height)"
            if let cached = prints[key] { return cached }
            guard let observation = try await compute() else { return nil }
            computed += 1
            prints[key] = observation
            return observation
        }
    }

    /// 1つのテンプレートを画面の候補と比べ、距離の小さい順に返す(閾値では絞らない)。
    /// **照合1回につき一様な白の特徴量を1つ作って縮退を確かめる**(候補ごとではない。約 4ms)。
    /// 縮退していたらテンプレートの控えも捨てる(縮退中に作った特徴量を次の回に使わない)
    public static func match(template: URL, elements: [ElementInfo], screen: FTRect, screenshot: CGImage,
                             tolerance: Double, prints: CandidatePrints) async throws -> [Match] {
        guard let templateImage = loadImage(template) else {
            throw MatchError.unreadableTemplate(template.path)
        }
        let candidates = candidates(in: elements, screen: screen,
                                    templateWidth: Double(templateImage.width),
                                    templateHeight: Double(templateImage.height), tolerance: tolerance)
        guard !candidates.isEmpty else { return [] }
        let templateObservation = try await templatePrint(template, image: templateImage, source: prints.source)
        // 縮退の門: 白紙は走査で1回だけ作る(判定は見本ごと = 距離の計算だけ)
        let blank: FeaturePrintObservation
        if let cached = prints.blank { blank = cached } else {
            blank = try await prints.source.compute(blankSentinel)
            prints.blank = blank
        }
        if isDegenerate(templateDistanceToBlank: try templateObservation.distance(to: blank)) {
            discardTemplatePrints(after: template)
            throw MatchError.degeneratePrints(template: template.lastPathComponent)
        }
        // 見本を取り直して控えと比べる(控えを作った時点・今のどちらかが壊れていれば一致しない)。
        // 撃つのは **走査の最初の見本(= 今の機械の状態)** と **このプロセスで初めて使う見本(= その控えの正しさ)** だけ。
        // 機械の異常は見本を選ばないので1枚で捕まり、見本ごとの控えは1回確かめれば以後は同じ(健全なら 1,200/1,200 で完全一致)
        let key = memoryKey(template)
        let firstUse = !templateLock.withLock { verifiedTemplateKeys.contains(key) }
        if !prints.machineRechecked || firstUse {
            prints.machineRechecked = true
            let selfDistance = Double(try templateObservation.distance(to: try await prints.source.compute(templateImage)))
            if !isConsistent(selfDistance: selfDistance) {
                discardTemplatePrints(after: template)
                throw MatchError.inconsistentPrints(template: template.lastPathComponent, distance: selfDistance)
            }
            templateLock.withLock { _ = verifiedTemplateKeys.insert(key) }
        }
        persistTemplatePrint(template, templateObservation)
        var matches: [Match] = []
        for candidate in candidates {
            guard let observation = try await prints.observation(for: candidate.visibleFrame, compute: {
                guard let crop = VisionClassifier.crop(image: screenshot, frame: candidate.visibleFrame, screen: screen)
                else { return nil }
                return try await prints.source.compute(crop)
            }) else { continue }
            let distance = try templateObservation.distance(to: observation)
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
