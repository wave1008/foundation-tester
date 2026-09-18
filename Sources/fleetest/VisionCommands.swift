// `fleetest vision` — 画像分類器(CheckStateClassifier / DefaultClassifier)の見本の採取と点検。
// 見本は**推論と同じ関数(VisionClassifier.crop)で a11y の枠から切る** = 切り方のずれで取り違える事故を作らない。

import ArgumentParser
import Foundation
import FTCore

struct VisionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vision",
        abstract: "Capture and check the sample images of the image classifiers (vision/classifiers/)",
        subcommands: [VisionCapture.self, VisionCheck.self])
}

struct VisionCapture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Crop an element from the live screen by its accessibility frame and save it as a sample image")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Classifier: CheckStateClassifier or DefaultClassifier")
    var classifier: String

    @Option(help: "Label folder under the classifier, e.g. \"[ON]\" or \"@i/Settings/[Camera Icon]\"")
    var label: String

    @Option(help: "Selector of the element to crop (same syntax as the DSL, e.g. \"#cb_agree\")")
    var selector: String

    @Option(help: "File name of the sample (default: capture-<date>.png)")
    var name: String?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let issue = VisionCaptureRules.labelIssue(classifier: classifier, label: label)
        if let issue { throw ValidationError(issue) }
        let project = try ScenarioHost.project(named: project)

        let driver = try await driverOptions.makeDriver()
        let snapshot = try await driver.snapshot()
        let parsed = FTSelector.parse(selector)
        let step = FlowStep(assert: "exists", locator: parsed.primary,
                            fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks)
        guard let (element, _) = StepExecutor.resolve(step: step, in: snapshot, strictForAssert: true) else {
            throw ValidationError("no element matches \(selector) on the current screen")
        }
        let png = try await driver.screenshot()
        guard let image = VisionClassifier.crop(png: png, frame: element.frame, screen: snapshot.screen),
              let data = VisionClassifier.pngData(image) else {
            throw ValidationError("could not crop \(selector) from the screenshot (is it inside the screen?)")
        }

        let classifierFolder = VisionClassifier.directory(projectRoot: project.rootURL, name: classifier)
        let folder = classifierFolder.appendingPathComponent(label, isDirectory: true)
        // 断ったときに片付けるため、これから作るフォルダ(深い順)を控える
        var created: [URL] = []
        var cursor = folder
        while !FileManager.default.fileExists(atPath: cursor.path) {
            created.append(cursor)
            cursor = cursor.deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name ?? VisionCaptureRules.defaultFileName(Date()))
        try data.write(to: file)
        // 同じ短いラベルが別のフォルダにあると学習できない(設定の誤り)ので、書いた直後に確かめて戻す
        do {
            _ = try VisionClassifier.trainingSet(at: classifierFolder)
        } catch {
            try? FileManager.default.removeItem(at: file)
            for directory in created { try? FileManager.default.removeItem(at: directory) }
            throw ValidationError("not saved: \(ErrorText.user(error))")
        }
        ConsoleOut.out("✅ saved \(image.width)x\(image.height) px of \(selector) to \(file.path)")
        ConsoleOut.out("   Check the classifier with: fleetest vision check --project \(project.name) --classifier \(classifier)")
    }
}

struct VisionCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Train the classifiers if needed and report the sample images each one cannot tell apart"
            + " (warnings only; the exit code stays 0)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Classifier to check (default: every folder under vision/classifiers/)")
    var classifier: String?

    func run() async throws {
        let project = try ScenarioHost.project(named: project)
        let root = project.rootURL.appendingPathComponent("vision/classifiers", isDirectory: true)
        let names = classifier.map { [$0] } ?? ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        if names.isEmpty {
            ConsoleOut.out("No classifiers under \(root.path)")
            return
        }
        for name in names {
            let directory = VisionClassifier.directory(projectRoot: project.rootURL, name: name)
            let set: VisionClassifier.TrainingSet?
            do {
                set = try VisionClassifier.trainingSet(at: directory)
            } catch {
                ConsoleOut.out("❌ \(name): \(ErrorText.user(error))")
                continue
            }
            guard let set else {
                ConsoleOut.out("⚠️ \(name): needs sample images in at least two label folders (\(directory.path))")
                continue
            }
            let model: VisionClassifier.Model
            do {
                model = try await VisionClassifier.load(
                    set, cacheDirectory: VisionClassifier.cacheDirectory(projectRoot: project.rootURL, name: name))
            } catch {
                ConsoleOut.out("❌ \(name): \(ErrorText.user(error))")
                continue
            }
            let samples = set.labels.values.reduce(0) { $0 + $1.count }
            ConsoleOut.out("\(model.mismatches.isEmpty ? "✅" : "⚠️") \(name): \(set.labels.count) labels, \(samples) samples")
            for label in set.labels.keys.sorted() {
                ConsoleOut.out("   \(label) (\(set.labels[label]!.count))")
            }
            for mismatch in model.mismatches {
                ConsoleOut.out("   ⚠️ \(VisionClassifier.describe(mismatch))")
            }
        }
    }
}

/// `vision capture` の純粋な判定(テスト用に切り出す)
enum VisionCaptureRules {
    static let knownClassifiers: Set<String> = [CheckStateClassifier.name, DefaultClassifier.name]

    /// 保存してから学習で気付く誤り(状態に写らないラベル・短いラベルの無いフォルダ)を先に断る
    static func labelIssue(classifier: String, label: String) -> String? {
        guard knownClassifiers.contains(classifier) else {
            return "unknown classifier \(classifier) (use \(knownClassifiers.sorted().joined(separator: " or ")))"
        }
        let leaf = label.split(separator: "/").last.map(String.init) ?? label
        if classifier == CheckStateClassifier.name, CheckStateClassifier.state(forLabel: leaf) == nil {
            return "a CheckStateClassifier label must contain [ON], [OFF] or [INDETERMINATE] (got \(label))"
        }
        if !leaf.contains("[") || !leaf.hasSuffix("]") {
            return "the label folder must end with a bracketed name such as [Camera Icon] (got \(label));"
                + " imageIs matches the part from the last ["
        }
        return nil
    }

    static func defaultFileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "capture-\(formatter.string(from: date)).png"
    }
}
