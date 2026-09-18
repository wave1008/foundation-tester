// Shirates(Vision)の画像分類器(vision/classifiers/<分類器名>/)の移植。要素の画像を Create ML の
// 画像分類器に掛ける。使い手は2つ: CheckStateClassifier(checkIsON/OFF)と DefaultClassifier(imageIs)。
//
// Shirates と同じ約束(VisionClassifierShard / LearningImageFileEntry):
//   - 見本は `<プロジェクト>/vision/classifiers/<分類器名>/` 以下の任意の深さの png/jpg。ラベルは
//     **画像の親フォルダを分類器フォルダからの相対パスで `_` につないだもの**(例 `@i_Settings_[Camera Icon]`)。
//     判定で見るのは**最後の `[` 以降**(短いラベル。LabelUtility.getShortLabel)
//   - `#` で始まるファイルはテキストの索引なので学習に使わない
//   - 同じ短いラベルのフォルダが2か所にあるのは設定の誤り(Shirates も例外にする)
//   - 同じフォルダの `MLImageClassifier.swift` の `// options=-noise,-blur` と `// imageFilter=binary` を読む
//     (augmentation と、学習画像の二値化版の追加。`-fp:N` は特徴抽出の版)
//   - 学習は MLImageClassifier(ScenePrint の転移学習 + ロジスティック回帰)。**ラベルが2つ未満なら使わない**
//   - 推論は1位のラベルだけを見る(shard 1・threshold 1.0 の Shirates と同じ。距離による再確認は通らない)
// 違い: Shirates は画像の区分け(SegmentContainer)で部品を切り出すが、fleetest は a11y の枠で切る。
// 見本画像も同じ枠で切ったものを置くこと(推論と学習で切り方を揃える)。分類器を複数の shard に割らない。
//
// 学習済みモデルは `<プロジェクト>/.fleetest/vision/<分類器名>/<digest>/model.mlmodel` に置き、
// 画像の中身・ラベル・オプション・学習器の版から作る digest が変わったときだけ学び直す。並列のシナリオ実行
// プロセスが同時に学ばないよう digest ごとの flock で1本にする(先客の完了を待って読む)。

import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
#if canImport(CreateML)
import CreateML
#endif

public enum VisionClassifier {
    /// 学習の手順を変えたら上げる(digest に入る = 古いキャッシュを使わない)
    static let trainerVersion = "2"
    /// 学習を待つ時間を締め切りから差し引くときの上限(DeadlineExclusion の cap)。
    /// 実測: Shirates の見本 16 枚で 7 秒(swift スクリプトの翻訳込み)。見本が数百枚でも数十秒の見込みで、
    /// 上限はシナリオの締め切りを延ばす最大幅(超えたら通常の締め切りへ戻るだけで、学習は止めない)
    static let trainingCap: Duration = .seconds(120)

    public static func directory(projectRoot: URL, name: String) -> URL {
        projectRoot.appendingPathComponent("vision/classifiers/\(name)", isDirectory: true)
    }

    public static func cacheDirectory(projectRoot: URL, name: String) -> URL {
        projectRoot.appendingPathComponent(".fleetest/vision/\(name)", isDirectory: true)
    }

    /// 判定で見る短いラベル(最後の `[` 以降。無ければ全体)。Shirates の LabelUtility.getShortLabel
    public static func shortLabel(_ label: String) -> String {
        guard let index = label.lastIndex(of: "[") else { return label }
        return String(label[index...])
    }

    // MARK: - 学習データ

    public struct Options: Equatable, Sendable {
        public var augmentation: Set<String> = []
        public var binary = false
        /// Shirates の既定(`-fp:N` で上書き)
        public var featurePrintRevision = 2

        static let augmentationNames: Set<String> = ["noise", "blur", "crop", "exposure", "flip", "rotation"]

        /// `MLImageClassifier.swift` の先頭コメント(Shirates の書式)を読む。無ければ既定
        public static func parse(scriptText: String?) -> Options {
            var options = Options()
            for line in (scriptText ?? "").split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                if let range = text.range(of: "options=") {
                    for raw in text[range.upperBound...].split(separator: ",") {
                        let token = raw.trimmingCharacters(in: .whitespaces)
                        if token.hasPrefix("-fp:"), let revision = Int(token.dropFirst(4)) {
                            options.featurePrintRevision = revision
                        } else if token.hasPrefix("-"), augmentationNames.contains(String(token.dropFirst())) {
                            options.augmentation.insert(String(token.dropFirst()))
                        }
                    }
                }
                if let range = text.range(of: "imageFilter=") {
                    options.binary = text[range.upperBound...].trimmingCharacters(in: .whitespaces) == "binary"
                }
            }
            return options
        }

        var fingerprint: String {
            "aug=\(augmentation.sorted().joined(separator: "+"));binary=\(binary);fp=\(featurePrintRevision)"
        }
    }

    public struct TrainingSet: Sendable {
        public let labels: [String: [URL]]
        public let options: Options
        public let digest: String
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]

    /// 画像を持つラベルが2つ以上あるときだけ返す(1ラベルでは分類器にならない。Shirates も学習しない)。
    /// 同じ短いラベルが2つのフォルダにあれば `LoadError.duplicateLabel`
    public static func trainingSet(at directory: URL) throws -> TrainingSet? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return nil }
        let rootComponents = directory.standardizedFileURL.pathComponents
        var labels: [String: [URL]] = [:]
        for case let file as URL in walker
        where imageExtensions.contains(file.pathExtension.lowercased()) && !file.lastPathComponent.hasPrefix("#") {
            let parent = file.deletingLastPathComponent().standardizedFileURL.pathComponents
            guard parent.count > rootComponents.count else { continue }   // 分類器フォルダ直下の画像はラベルを持たない
            labels[parent.dropFirst(rootComponents.count).joined(separator: "_"), default: []].append(file)
        }
        for key in labels.keys { labels[key]!.sort { $0.lastPathComponent < $1.lastPathComponent } }
        let byShort = Dictionary(grouping: labels.keys, by: shortLabel)
        if let (short, keys) = byShort.first(where: { $0.value.count > 1 }) {
            throw LoadError.duplicateLabel(short, keys.sorted())
        }
        guard labels.count >= 2 else { return nil }
        let script = try? String(contentsOf: directory.appendingPathComponent("MLImageClassifier.swift"), encoding: .utf8)
        let options = Options.parse(scriptText: script)
        var hasher = SHA256()
        hasher.update(data: Data("\(directory.lastPathComponent);v\(trainerVersion);\(options.fingerprint)".utf8))
        for label in labels.keys.sorted() {
            for image in labels[label]! {
                hasher.update(data: Data("\(label)/\(image.lastPathComponent)".utf8))
                hasher.update(data: (try? Data(contentsOf: image)) ?? Data())
            }
        }
        let digest = hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
        return TrainingSet(labels: labels, options: options, digest: digest)
    }

    // MARK: - モデル

    public struct Classification: Sendable, Equatable {
        public let label: String
        public let confidence: Double
    }

    public final class Model: @unchecked Sendable {
        let vnModel: VNCoreMLModel
        /// 学習したラベル(フォルダの相対パスを `_` でつないだもの)
        public let labels: [String]
        init(vnModel: VNCoreMLModel, labels: [String]) { self.vnModel = vnModel; self.labels = labels }

        /// 1位のラベル。Shirates と同じく確信度 0.1 以下は候補にしない
        public func classify(_ image: CGImage) throws -> Classification? {
            let request = VNCoreMLRequest(model: vnModel)
            try VNImageRequestHandler(cgImage: image).perform([request])
            let observations = (request.results as? [VNClassificationObservation]) ?? []
            guard let best = observations.max(by: { $0.confidence < $1.confidence }), best.confidence > 0.1
            else { return nil }
            return Classification(label: best.identifier, confidence: Double(best.confidence))
        }
    }

    public enum LoadError: Error, CustomStringConvertible {
        case createMLUnavailable
        case training(String)
        case duplicateLabel(String, [String])
        public var description: String {
            switch self {
            case .createMLUnavailable: return "Create ML is not available on this host"
            case .training(let detail): return "training failed: \(detail)"
            case .duplicateLabel(let label, let folders):
                return "the label \(label) is in more than one folder (\(folders.joined(separator: ", "))); a label can belong to only one folder"
            }
        }
    }

    private static let processLock = NSLock()
    private static var loaded: [String: Model] = [:]

    /// プロセス内の控えを捨てる(ファイルのキャッシュから読み直すことをテストで確かめるため)
    static func forgetLoadedModelsForTesting() {
        processLock.lock(); loaded = [:]; processLock.unlock()
    }

    /// 学習済みモデルを返す(無ければ学ぶ)。**ブロックする** —— 協調スレッドプールの上で呼ばない
    /// (呼び手は `load(_:cacheDirectory:)` の async 版)
    public static func loadBlocking(_ set: TrainingSet, cacheDirectory: URL) throws -> Model {
        processLock.lock()
        defer { processLock.unlock() }
        if let model = loaded[set.digest] { return model }
        let work = cacheDirectory.appendingPathComponent(set.digest, isDirectory: true)
        let modelURL = work.appendingPathComponent("model.mlmodel")
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let lockPath = cacheDirectory.appendingPathComponent("\(set.digest).lock").path
            // FileManager.createFile を使わない(既存の inode を置き換えて先客の flock と衝突しなくなる)
            let fd = open(lockPath, O_WRONLY | O_CREAT, 0o644)
            if fd >= 0 { flock(fd, LOCK_EX) }
            defer { if fd >= 0 { close(fd) } }
            if !FileManager.default.fileExists(atPath: modelURL.path) {
                try train(set, into: work, modelURL: modelURL)
            }
        }
        let compiled = try MLModel.compileModel(at: modelURL)
        let model = Model(vnModel: try VNCoreMLModel(for: MLModel(contentsOf: compiled)),
                          labels: set.labels.keys.sorted())
        loaded[set.digest] = model
        return model
    }

    /// 学習(キャッシュに無いとき)の待ちは締め切りから差し引く(DeadlineExclusion。OCR の暖機と同じ扱い)
    public static func load(_ set: TrainingSet, cacheDirectory: URL) async throws -> Model {
        let needsTraining = !FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent("\(set.digest)/model.mlmodel").path)
        let token = needsTraining ? DeadlineExclusion.begin(cap: trainingCap) : nil
        defer { if let token { DeadlineExclusion.end(token) } }
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do { continuation.resume(returning: try loadBlocking(set, cacheDirectory: cacheDirectory)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func train(_ set: TrainingSet, into work: URL, modelURL: URL) throws {
        #if canImport(CreateML)
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        let training = work.appendingPathComponent("training", isDirectory: true)
        for (label, images) in set.labels {
            let dir = training.appendingPathComponent(label, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for image in images {
                try fm.copyItem(at: image, to: dir.appendingPathComponent(image.lastPathComponent))
                if set.options.binary { writeBinaryVariants(of: image, into: dir) }
            }
        }
        var augmentation = MLImageClassifier.ImageAugmentationOptions()
        for name in set.options.augmentation {
            switch name {
            case "noise": augmentation.insert(.noise)
            case "blur": augmentation.insert(.blur)
            case "crop": augmentation.insert(.crop)
            case "exposure": augmentation.insert(.exposure)
            case "flip": augmentation.insert(.flip)
            case "rotation": augmentation.insert(.rotation)
            default: break
            }
        }
        let parameters = MLImageClassifier.ModelParameters(
            validation: .split(strategy: .automatic),
            augmentation: augmentation,
            algorithm: .transferLearning(
                featureExtractor: .scenePrint(revision: set.options.featurePrintRevision),
                classifier: .logisticRegressor))
        do {
            let classifier = try MLImageClassifier(trainingData: .labeledDirectories(at: training),
                                                   parameters: parameters)
            let temporary = work.appendingPathComponent("model.tmp.mlmodel")
            try classifier.write(to: temporary)
            try fm.moveItem(at: temporary, to: modelURL)
        } catch {
            throw LoadError.training(String(describing: error))
        }
        #else
        throw LoadError.createMLUnavailable
        #endif
    }

    // MARK: - 画像

    /// 要素の枠でスクリーンショットを切り出す。枠はスナップショットの座標系(iOS = pt / Android = px)で、
    /// 画像との倍率は画面の幅の比から導く
    public static func crop(png: Data, frame: FTRect, screen: FTRect) -> CGImage? {
        guard screen.width > 0,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let scale = Double(image.width) / screen.width
        let rect = CGRect(x: (frame.x - screen.x) * scale, y: (frame.y - screen.y) * scale,
                          width: frame.width * scale, height: frame.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        return image.cropping(to: rect)
    }

    /// `imageFilter=binary` の学習画像: 大津の閾値で二値化した画像と、その白黒反転を足す
    /// (Shirates の VisionClassifierShard.createBinaryFile と同じ2枚)
    static func writeBinaryVariants(of imageURL: URL, into directory: URL) {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let gray = grayscalePixels(image) else { return }
        let threshold = otsuThreshold(gray.pixels)
        let base = imageURL.deletingPathExtension().lastPathComponent
        for (suffix, inverted) in [("_binary", false), ("_binary2", true)] {
            let pixels = gray.pixels.map { ($0 <= threshold) != inverted ? UInt8(255) : UInt8(0) }
            writePNG(pixels: pixels, width: gray.width, height: gray.height,
                     to: directory.appendingPathComponent("\(base)\(suffix).png"))
        }
    }

    static func grayscalePixels(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }

    /// 大津の方法(クラス間分散最大)。戻り値以下が片側
    static func otsuThreshold(_ pixels: [UInt8]) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for p in pixels { histogram[Int(p)] += 1 }
        let total = Double(pixels.count)
        let sumAll = (0..<256).reduce(0.0) { $0 + Double($1 * histogram[$1]) }
        var sumBelow = 0.0, countBelow = 0.0, best = 0.0, threshold = 0
        for t in 0..<256 {
            countBelow += Double(histogram[t])
            if countBelow == 0 { continue }
            let countAbove = total - countBelow
            if countAbove == 0 { break }
            sumBelow += Double(t * histogram[t])
            let meanBelow = sumBelow / countBelow
            let meanAbove = (sumAll - sumBelow) / countAbove
            let variance = countBelow * countAbove * (meanBelow - meanAbove) * (meanBelow - meanAbove)
            if variance > best { best = variance; threshold = t }
        }
        return UInt8(threshold)
    }

    static func writePNG(pixels: [UInt8], width: Int, height: Int, to url: URL) {
        var data = pixels
        guard let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}


/// checkIsON / checkIsOFF の画像判定(Shirates Vision の CheckStateClassifier)
public enum CheckStateClassifier {
    public static let name = "CheckStateClassifier"

    public static func directory(projectRoot: URL) -> URL {
        VisionClassifier.directory(projectRoot: projectRoot, name: name)
    }

    public static func cacheDirectory(projectRoot: URL) -> URL {
        VisionClassifier.cacheDirectory(projectRoot: projectRoot, name: name)
    }

    /// ラベル名 → 状態。Shirates の checkIsON は `label.contains("[ON]")`。
    /// `[INDETERMINATE]` は fleetest 独自(Shirates はどちらにも当たらず両方落ちる = 結果は同じで、理由を言える)
    public static func state(forLabel label: String) -> CheckState? {
        if label.contains("[INDETERMINATE]") { return .indeterminate }
        if label.contains("[ON]") { return .on }
        if label.contains("[OFF]") { return .off }
        return nil
    }
}

/// imageIs の画像判定(Shirates Vision の DefaultClassifier)
public enum DefaultClassifier {
    public static let name = "DefaultClassifier"

    /// Shirates の imageIs: 1位のラベルの短いラベルが期待値を含むか
    public static func matches(label: String, expected: String) -> Bool {
        VisionClassifier.shortLabel(label).contains(expected)
    }
}
