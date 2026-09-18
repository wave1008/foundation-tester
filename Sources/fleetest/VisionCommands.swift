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
        if let issue = VisionSample.labelIssue(classifier: classifier, label: label) { throw ValidationError(issue) }
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
        guard let image = VisionClassifier.crop(png: png, frame: element.frame, screen: snapshot.screen) else {
            throw ValidationError("could not crop \(selector) from the screenshot (is it inside the screen?)")
        }
        let file: URL
        do {
            file = try VisionSample.save(image, projectRoot: project.rootURL, classifier: classifier,
                                         label: label, name: name)
        } catch {
            throw ValidationError(ErrorText.user(error))
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
            for line in await VisionSample.report(projectRoot: project.rootURL, classifier: name).lines {
                ConsoleOut.out(line)
            }
        }
    }
}
