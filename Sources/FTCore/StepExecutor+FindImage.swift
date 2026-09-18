// StepExecutor+FindImage.swift
// findImage / findImages(Shirates Vision の移植)のアクション。照合の中核は FindImage.swift。
// **見つからなくても失敗にしない**(select と同じ = ユーザー決定。見つけた要素は
// `imageMatchesThisStep` → StepOutcome.imageMatches で DSL へ返し、空なら空要素)。
// 失敗にするのは設定の誤り(テンプレートが無い・引数が範囲外・scrollFrame が解決できない)と、
// Vision が答えを出せない状態(縮退 = `FindImage.isDegenerate` / 要求の失敗 = execution error)だけ。

import CoreGraphics
import Foundation
import ImageIO

extension StepExecutor {

    static func isFindImageAction(_ action: String) -> Bool {
        action == "findImage" || action == "findImages"
    }

    func executeFindImage(_ action: String, step: FlowStep,
                          phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let single = action == "findImage"
        let label = step.expected ?? ""
        let tolerance = step.aspectRatioTolerance ?? FindImage.defaultAspectRatioTolerance
        if let error = FindImage.validate(aspectRatioTolerance: tolerance) {
            return StepOutcome(status: .failed(error))
        }
        guard let root = visionClassifierProjectRoot else {
            return StepOutcome(status: .failed("\(action) needs the project directory to read template images"
                + " from vision/classifiers/\(DefaultClassifier.name)"))
        }
        let directory = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
        let allTemplates = FindImage.templateFiles(label: label, classifierDirectory: directory, isAndroid: isAndroid)
        guard !allTemplates.isEmpty else {
            return StepOutcome(status: .failed(FindImage.MatchError.noTemplate(
                label: label, directory: "vision/classifiers/\(DefaultClassifier.name)").description))
        }
        // findImages は Shirates の VisionClassifier.getFile と同じく1枚(自 OS 用を優先)だけを使う
        let templates = single ? allTemplates : [allTemplates[0]]
        let threshold: Double? = single ? (step.imageThreshold ?? FindImage.defaultThreshold) : step.imageThreshold

        var notes: [String] = []
        var scan = ImageScan(found: [], nearest: nil, classified: false)
        if let rawDirection = step.direction {
            let direction = FTSwipeDirection(rawValue: rawDirection) ?? .up
            let maxSwipes = max(0, step.maxSwipes ?? FlowStep.defaultMaxSwipes)
            var previous: String?
            var unchanged = 0
            var swipes = 0
            var viaXCUITest = false
            for attempt in 0...maxSwipes {
                // 送った直後は整定を待ってから撮る(スクロール探索と同じ。動いている画面を切り出さない)
                var snapshot = try await settledSignature(phase: &phase).snapshot
                try await dismissInterruption(in: &snapshot, phase: &phase)
                scan = try await scanImage(templates: templates, label: label, single: single,
                                           threshold: threshold, tolerance: tolerance,
                                           snapshot: snapshot, carried: scan.nearest, phase: &phase)
                if !scan.found.isEmpty || attempt == maxSwipes { break }
                // 2周続けて木が変わらなければ端(runScrollSearch と同じ打ち切り。1周で切らないのは
                // 遅れて描画される行を「動かなかった」と誤断しないため)
                let signature = Self.edgeSignature(snapshot)
                unchanged = signature == previous ? unchanged + 1 : 0
                previous = signature
                if unchanged >= 2 { break }
                if Self.scrollFrameUnresolved(step, in: snapshot) {
                    noteCodesThisStep.insert(.scrollFrameMissing)
                    return StepOutcome(status: failed(
                        .notFound, Self.scrollFrameFailFastMessage(step, action: "swipe", swipes: swipes)))
                }
                if try await swipeWithFallback(direction, intent: .search,
                                               path: scrollPath(step: step, intent: .search, in: snapshot),
                                               phase: &phase) { viaXCUITest = true }
                swipes += 1
            }
            scrollSwipesThisStep = swipes
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if swipes > 0 { notes.append("\(swipes) swipe\(swipes == 1 ? "" : "s")") }
        } else {
            let clock = ContinuousClock()
            let deadline = Date().addingTimeInterval(step.timeout ?? FlowStep.defaultWaitSeconds)
            var backoff = PollBackoff()
            while true {
                let start = clock.now
                var snapshot = try await driver.snapshot(bypassingCache: false)
                phase.snapshotMs += Self.ms(clock.now - start)
                try await dismissInterruption(in: &snapshot, phase: &phase)
                scan = try await scanImage(templates: templates, label: label, single: single,
                                           threshold: threshold, tolerance: tolerance,
                                           snapshot: snapshot, carried: scan.nearest, phase: &phase)
                if !scan.found.isEmpty || Date() >= deadline { break }
                let waitStart = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - waitStart)
            }
        }
        notes.insert(Self.findImageNote(scan, single: single, threshold: threshold), at: 0)
        notes.insert("\(scan.compared) compared", at: 1)
        imageMatchesThisStep = scan.found
        if single { resolvedElementThisStep = scan.found.first?.element }
        return StepOutcome(status: .passed, driverFallback: notes.joined(separator: " / "))
    }

    struct ImageScan {
        var found: [FindImage.Match]
        /// 見つからなかったときの理由文に使う、最も近かった候補(周回を跨いで最小を持つ)
        var nearest: FindImage.Match?
        /// findImage の1位が閾値を超え、DefaultClassifier の分類(classificationConfirmed)で採った
        var classified: Bool
        /// 最後に照合した画面で特徴量を比べた候補の数(テンプレートを複数試したら合計)。所要の説明に出す
        var compared = 0
    }

    /// 1枚の画面で照合する。findImage はテンプレートを順に試し、最初に見つかった1件で止める
    /// (Shirates の findImageCore)。1位が閾値を超えたら1位の画像を DefaultClassifier に掛け、
    /// 短いラベルが一致し、かつ `classificationConfirmed` が通れば採る(分類器が無い・学べないときは
    /// この救済を飛ばす)
    private func scanImage(templates: [URL], label: String, single: Bool, threshold: Double?,
                           tolerance: Double, snapshot: SnapshotResponse, carried: FindImage.Match?,
                           phase: inout PhaseAccumulator) async throws -> ImageScan {
        let clock = ContinuousClock()
        let shotStart = clock.now
        let png = try await driver.screenshot()
        phase.snapshotMs += Self.ms(clock.now - shotStart)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let screenshot = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ImageScan(found: [], nearest: carried, classified: false)
        }
        let matchStart = clock.now
        defer { phase.actionMs += Self.ms(clock.now - matchStart) }
        var nearest = carried
        var compared = 0
        func named(_ matches: [FindImage.Match], classified: Bool) -> ImageScan {
            guard !matches.isEmpty else {
                return ImageScan(found: [], nearest: nearest, classified: false, compared: compared)
            }
            let naming = SelectorNaming(snapshot)
            return ImageScan(found: matches.map { match in
                var match = match
                match.selector = naming.selector(for: match.element, in: snapshot)
                return match
            }, nearest: nearest, classified: classified, compared: compared)
        }
        for template in templates {
            let matches = try await FindImage.match(template: template, elements: snapshot.elements,
                                                    screen: snapshot.screen, screenshot: screenshot,
                                                    tolerance: tolerance)
            compared += matches.count
            if let first = matches.first, first.distance < (nearest?.distance ?? .infinity) { nearest = first }
            guard single else {
                return named(threshold.map { limit in matches.filter { $0.distance < limit } } ?? matches,
                             classified: false)
            }
            guard let primary = matches.first else { continue }
            let limit = threshold ?? FindImage.defaultThreshold
            if primary.distance <= limit {
                return named([primary], classified: false)
            }
            if let classifier = await loadedVisionClassifier(DefaultClassifier.name),
               let crop = VisionClassifier.crop(image: screenshot, frame: primary.visibleFrame, screen: snapshot.screen),
               let classification = try? classifier.classify(crop),
               VisionClassifier.shortLabel(classification.label) == VisionClassifier.shortLabel(label),
               try await Self.classificationConfirmed(classification, crop: crop, templates: templates, threshold: limit) {
                return named([primary], classified: true)
            }
        }
        return ImageScan(found: [], nearest: nearest, classified: false, compared: compared)
    }

    /// Shirates の VisionElement.classifyFull と同じ確かめ方: 分類器の1位だけでは採らない
    /// (分類器は見本のどれかのラベルを必ず答えるので、ラベルが少ないと無関係な画像にも
    /// 探しているラベルを返す)。採るのは ①確信度が閾値以下(Shirates の shard 1 の枝をそのまま移した)
    /// か ②そのラベルの見本のどれかとの特徴量の距離が閾値以下 のときだけ
    static func classificationConfirmed(_ classification: VisionClassifier.Classification, crop: CGImage,
                                        templates: [URL], threshold: Double) async throws -> Bool {
        if classification.confidence <= threshold { return true }
        let observation = try await FindImage.featurePrint(crop)
        for template in templates {
            guard let image = FindImage.loadImage(template) else { continue }
            let print = try await FindImage.templatePrint(template, image: image)
            if try print.distance(to: observation) <= threshold { return true }
        }
        return false
    }

    /// 記録の括弧書き(見つけた距離・見つからなかった理由)。数字は照合をやり直さずに閾値を
    /// 決め直せるようにするため必ず出す
    static func findImageNote(_ scan: ImageScan, single: Bool, threshold: Double?) -> String {
        // 0.001 未満を %.3f で出すと「0.000 > threshold 0.000」になり比べられない
        func format(_ value: Double) -> String {
            value != 0 && abs(value) < 0.001 ? String(format: "%.1e", value) : String(format: "%.3f", value)
        }
        let limit = threshold.map { " threshold \(format($0))" } ?? ""
        if single {
            if let match = scan.found.first {
                return scan.classified
                    ? "found by \(DefaultClassifier.name) (distance \(format(match.distance)) >\(limit))"
                    : "found (distance \(format(match.distance)))"
            }
            guard let nearest = scan.nearest else { return "not found (no element of a similar aspect ratio)" }
            return "not found (nearest distance \(format(nearest.distance)) >\(limit))"
        }
        if scan.found.isEmpty {
            guard let nearest = scan.nearest else { return "0 found (no element of a similar aspect ratio)" }
            return "0 found (nearest distance \(format(nearest.distance)),\(limit))"
        }
        return "\(scan.found.count) found (distance \(scan.found.map { format($0.distance) }.joined(separator: ", ")))"
    }
}
