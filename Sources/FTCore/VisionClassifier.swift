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
// 学習済みモデルは分類器ごとに1か所(`<プロジェクト>/.fleetest/vision/<分類器名>/model.mlmodel`)に置き、
// 隣の `digest` に「どの見本から作ったか」(画像の中身・ラベル・オプション・学習器の版から作る digest)を書く。
// **digest が一致しないときだけ学び直して上書きする**。並列のシナリオ実行プロセスは分類器ごとの flock
// (`train.lock`)を通って確認・学習・読み込みをするので、見本の更新1回につき学習は1回(先客の完了を待って読む)。

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
        /// 分類器フォルダ(`vision/classifiers/<分類器名>/`)
        public let directory: URL
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
        return TrainingSet(directory: directory, labels: labels, options: options, digest: digest)
    }

    // MARK: - モデル

    public struct Classification: Sendable, Equatable {
        public let label: String
        public let confidence: Double
    }

    /// 学習の点検で、モデルが自分の見本を取り違えた1件(見本のラベルと違うラベルを1位に答えた)。
    /// **閾値を持たない** —— 自分の見本すら見分けられないラベルは、本番の画像でも取り違えうる、という事実だけ
    public struct Mismatch: Codable, Sendable, Equatable {
        /// 分類器フォルダからの相対パス
        public let sample: String
        public let expected: String
        /// nil = どのラベルも確信度 0.1 を超えなかった
        public let predicted: String?
        public let confidence: Double

        public init(sample: String, expected: String, predicted: String?, confidence: Double) {
            self.sample = sample; self.expected = expected; self.predicted = predicted; self.confidence = confidence
        }
    }

    public final class Model: @unchecked Sendable {
        let vnModel: VNCoreMLModel
        /// 学習したラベル(フォルダの相対パスを `_` でつないだもの)
        public let labels: [String]
        /// 学習の点検で取り違えた見本(空 = 全見本を正しく答えた)
        public internal(set) var mismatches: [Mismatch] = []
        /// 推論のたびに一緒に掛ける対照 = ラベルの違う見本2枚(点検で正しく答えたものから `controlSamples` が選ぶ)。
        /// 空 = 選べなかった(確かめずに答える)
        var controls: [Control] = []
        /// テスト用の推論の差し替え口(Core ML の縮退は意図的に起こせない)
        var inferenceForTesting: ((CGImage) throws -> Classification?)?
        init(vnModel: VNCoreMLModel, labels: [String]) { self.vnModel = vnModel; self.labels = labels }

        struct Control {
            let label: String
            let image: CGImage
        }

        /// 1位のラベル。Shirates と同じく確信度 0.1 以下は候補にしない。
        /// **対照が自分のラベルに答えなければ答えを使わない**(`ClassifyError.controlMismatch`)——
        /// Vision / Core ML は壊れても失敗を返さず、どの画像にも同じラベルを確信度 1.00 で答える
        /// (負荷テストで実測: ON が写った crop を [OFF] 1.00 と 7 回答え、同じ crop・同じモデルを
        /// 後で掛けると 20/20 [ON] 1.00)。1推論ごとに VisionUsageLedger へ1件書く
        /// (ロックの内側から呼ぶ経路は `classifyUnrecorded`)
        public func classify(_ image: CGImage) throws -> Classification? {
            let answer = try recorded { try classifyUnrecorded(image) }
            for control in controls {
                let got = try recorded { try classifyUnrecorded(control.image) }
                guard got?.label == control.label else {
                    throw ClassifyError.controlMismatch(expected: control.label, got: got)
                }
            }
            return answer
        }

        private func recorded(_ body: () throws -> Classification?) throws -> Classification? {
            let start = Date()
            do {
                let answer = try body()
                VisionUsageLedger.record(ok: true, ms: Date().timeIntervalSince(start) * 1000)
                return answer
            } catch {
                VisionUsageLedger.record(ok: false, ms: Date().timeIntervalSince(start) * 1000)
                throw error
            }
        }

        func classifyUnrecorded(_ image: CGImage) throws -> Classification? {
            if let inferenceForTesting { return try inferenceForTesting(image) }
            let request = VNCoreMLRequest(model: vnModel)
            try VNImageRequestHandler(cgImage: image).perform([request])
            let observations = (request.results as? [VNClassificationObservation]) ?? []
            guard let best = observations.max(by: { $0.confidence < $1.confidence }), best.confidence > 0.1
            else { return nil }
            return Classification(label: best.identifier, confidence: Double(best.confidence))
        }
    }

    public enum ClassifyError: LocalizedError, CustomStringConvertible {
        case controlMismatch(expected: String, got: Classification?)
        public var description: String {
            switch self {
            case .controlMismatch(let expected, let got):
                let answered = got.map { "\"\($0.label)\" (confidence \(String(format: "%.2f", $0.confidence)))" }
                    ?? "no label"
                return "the classifier answered \(answered) for its own sample image of \"\(expected)\","
                    + " so Vision / Core ML is not answering reliably on this machine right now and its answer"
                    + " was not used; this is a transient state of the machine (retry the run; if it persists, reboot)"
            }
        }
        public var errorDescription: String? { description }
    }

    public enum LoadError: LocalizedError, CustomStringConvertible {
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
        public var errorDescription: String? { description }
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
        // 学習と点検の推論は processLock の内側で走るので、控えへの記録は解放の後にまとめて書く
        // (VisionUsageLedger.record はファイル I/O をするのでロックの外から呼ぶ規律)。
        // defer は逆順に走る = unlock → 記録
        var usage = VisionUsage()
        defer { usage.flush() }
        processLock.lock()
        defer { processLock.unlock() }
        if let model = loaded[set.digest] { return model }
        // 読み込みもロックを通す: 別プロセスが上書きしている最中のモデル・点検結果を読まない
        let model = try withCacheLock(cacheDirectory) {
            _ = try ensureModel(set, cacheDirectory: cacheDirectory, usage: &usage)
            let compiled = try MLModel.compileModel(at: CacheLayout.model(cacheDirectory))
            let model = Model(vnModel: try VNCoreMLModel(for: MLModel(contentsOf: compiled)),
                              labels: set.labels.keys.sorted())
            model.mismatches = selfCheck(model, set, cachedAt: CacheLayout.selfCheck(cacheDirectory), usage: &usage)
            return model
        }
        model.controls = controlSamples(set, excluding: model.mismatches)
        loaded[set.digest] = model
        return model
    }

    /// 分類器ごとの置き場所(`cacheDirectory` 直下)。モデル・点検結果・digest は1組だけ持つ
    enum CacheLayout {
        static func model(_ dir: URL) -> URL { dir.appendingPathComponent("model.mlmodel") }
        static func selfCheck(_ dir: URL) -> URL { dir.appendingPathComponent("selfcheck.json") }
        static func digest(_ dir: URL) -> URL { dir.appendingPathComponent("digest") }
        static func training(_ dir: URL) -> URL { dir.appendingPathComponent("training", isDirectory: true) }
        static func lock(_ dir: URL) -> URL { dir.appendingPathComponent("train.lock") }
    }

    /// 置き場所のモデルが `set` から作ったものでないか(無い・digest が違う)。ロックを取らずに読む = 目安にだけ使う
    static func isStale(_ set: TrainingSet, cacheDirectory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: CacheLayout.model(cacheDirectory).path),
              let stamp = try? String(contentsOf: CacheLayout.digest(cacheDirectory), encoding: .utf8)
        else { return true }
        return stamp != set.digest
    }

    /// 分類器ごとの flock を取って `body` を走らせる。**同じプロセスの別スレッドどうしも排他になる**
    /// (flock は open ごとの記述子に付くので、open し直した fd どうしは衝突する)
    static func withCacheLock<T>(_ cacheDirectory: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // FileManager.createFile を使わない(既存の inode を置き換えて先客の flock と衝突しなくなる)
        let fd = open(CacheLayout.lock(cacheDirectory).path, O_WRONLY | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }
        return try body()
    }

    /// **`withCacheLock` の内側で呼ぶ**。置き場所のモデルが `set` から作ったものでなければ学び直して上書きし、
    /// 学んだら true。確認をロックの内側でもう一度するので、同時に来たプロセスのうち学ぶのは最初の1本だけ
    /// (後の者は先客が書いた digest を見て読むだけになる)。順序: 点検結果を消す → 学習 → モデルを差し替え →
    /// digest を最後に書く(途中で落ちても digest が古いまま = 次の者が学び直す)
    static func ensureModel(_ set: TrainingSet, cacheDirectory: URL, usage: inout VisionUsage) throws -> Bool {
        guard isStale(set, cacheDirectory: cacheDirectory) else { return false }
        try? FileManager.default.removeItem(at: CacheLayout.selfCheck(cacheDirectory))
        try usage.measure { try train(set, cacheDirectory: cacheDirectory) }
        try Data(set.digest.utf8).write(to: CacheLayout.digest(cacheDirectory), options: .atomic)
        return true
    }

    /// ロックの内側で撃った Vision / Core ML の呼び出しを控え、ロックの外で VisionUsageLedger へ書く
    struct VisionUsage {
        private var calls: [(ok: Bool, ms: Double)] = []

        mutating func measure<T>(_ body: () throws -> T) throws -> T {
            let start = Date()
            do {
                let value = try body()
                calls.append((true, Date().timeIntervalSince(start) * 1000))
                return value
            } catch {
                calls.append((false, Date().timeIntervalSince(start) * 1000))
                throw error
            }
        }

        func flush() {
            for call in calls { VisionUsageLedger.record(ok: call.ok, ms: call.ms) }
        }
    }

    /// 学習の点検: 見本の1枚1枚を学習したモデル自身に掛け、見本のラベルと違う答えを集める。
    /// 結果はモデルの隣に控え、同じ digest では掛け直さない(見本が変われば digest が変わる)
    static func selfCheck(_ model: Model, _ set: TrainingSet, cachedAt url: URL, usage: inout VisionUsage) -> [Mismatch] {
        if let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode([Mismatch].self, from: data) {
            return cached
        }
        var mismatches: [Mismatch] = []
        for (label, images) in set.labels.sorted(by: { $0.key < $1.key }) {
            for image in images {
                guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                let answer = try? usage.measure { try model.classifyUnrecorded(cgImage) }
                guard answer?.label != label else { continue }
                mismatches.append(Mismatch(sample: samplePath(image, in: set), expected: label,
                                           predicted: answer?.label, confidence: answer?.confidence ?? 0))
            }
        }
        if let data = try? JSONEncoder().encode(mismatches) { try? data.write(to: url) }
        return mismatches
    }

    /// 分類器フォルダからの相対パス(Mismatch.sample の書式)
    static func samplePath(_ image: URL, in set: TrainingSet) -> String {
        let root = set.directory.standardizedFileURL.path + "/"
        let path = image.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// 推論のたびに掛ける対照(`Model.controls`)。**ラベルの違う2枚**で足りる —— 壊れた推論は全部に同じ
    /// ラベルを答えるので、2つのラベルのどちらかを必ず外す。点検で取り違えた見本は選ばない(健全なときも
    /// 外すので対照にならない)。2枚そろわなければ空 = 確かめない
    static func controlSamples(_ set: TrainingSet, excluding mismatches: [Mismatch]) -> [Model.Control] {
        let wrong = Set(mismatches.map(\.sample))
        var picked: [Model.Control] = []
        for (label, images) in set.labels.sorted(by: { $0.key < $1.key }) where picked.count < 2 {
            for url in images where !wrong.contains(samplePath(url, in: set)) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                picked.append(Model.Control(label: label, image: image))
                break
            }
        }
        return picked.count == 2 ? picked : []
    }

    /// 取り違えの1行の説明(シナリオ終了時の警告と `fleetest vision check` が同じ文を出す)
    public static func describe(_ mismatch: Mismatch) -> String {
        let predicted = mismatch.predicted.map { "\"\($0)\" (confidence \(String(format: "%.2f", mismatch.confidence)))" }
            ?? "no label"
        return "\(mismatch.sample) is classified as \(predicted), not \"\(mismatch.expected)\""
    }

    /// 切り出した画像を PNG にする(`fleetest vision capture`)
    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 学習(キャッシュに無いとき)の待ちは締め切りから差し引く(DeadlineExclusion。OCR の暖機と同じ扱い)
    public static func load(_ set: TrainingSet, cacheDirectory: URL) async throws -> Model {
        let needsTraining = isStale(set, cacheDirectory: cacheDirectory)
        let token = needsTraining ? DeadlineExclusion.begin(cap: trainingCap) : nil
        defer { if let token { DeadlineExclusion.end(token) } }
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do { continuation.resume(returning: try loadBlocking(set, cacheDirectory: cacheDirectory)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// 学習してモデルを置き場所へ差し替える(`ensureModel` からだけ呼ぶ = ロックの内側)
    private static func train(_ set: TrainingSet, cacheDirectory: URL) throws {
        #if canImport(CreateML)
        let fm = FileManager.default
        let training = CacheLayout.training(cacheDirectory)
        try? fm.removeItem(at: training)
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
            let temporary = cacheDirectory.appendingPathComponent("model.tmp.mlmodel")
            try? fm.removeItem(at: temporary)
            try classifier.write(to: temporary)
            // rename(2) は置き換えを一度に行う(moveItem は既存があると失敗する)
            guard rename(temporary.path, CacheLayout.model(cacheDirectory).path) == 0 else {
                throw LoadError.training("could not replace the model (errno \(errno))")
            }
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
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return crop(image: image, frame: frame, screen: screen)
    }

    /// 復号済みのスクリーンショットから切る(同じ画面から何枚も切る findImage は復号を1回にする)
    public static func crop(image: CGImage, frame: FTRect, screen: FTRect) -> CGImage? {
        guard screen.width > 0 else { return nil }
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


/// checkIsON / checkIsOFF が状態を読む先の優先(DSL の `prefer:`。実行プロファイルの
/// `preferCheckStateClassifier` を1コマンドだけ上書きする)。意味はプロファイルのキーと同じ:
/// `.classifier` = 見本があれば分類器で判定 / `.accessibility` = a11y が状態を報告する要素は a11y で、
/// 報告しない要素(自作の部品・オンを見る前の Compose の Checkbox 等)だけ分類器
public enum CheckStateSource: String, Sendable, CaseIterable {
    case classifier, accessibility
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
