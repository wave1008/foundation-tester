// AppModel.swift
// GUI の状態管理。実行・探索・ライブ操作のロジックは既存モジュール
// (Replayer / ExplorerAgent / BridgeClient / AndroidDriver)をそのまま使う。

import AppKit
import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore
import Observation

@MainActor
@Observable
final class AppModel {

    // MARK: - ドライバ設定

    var platform = "ios"
    var portText = "8123"
    var serial = ""
    var connectionStatus = "未確認"
    var connected = false

    // MARK: - フロー実行

    struct FlowEntry: Identifiable {
        let url: URL
        var flow: Flow
        var state: RunState = .idle
        var id: URL { url }
    }

    enum RunState {
        case idle, running, passed, failed
    }

    var flows: [FlowEntry] = []
    var selectedFlowID: URL?
    var heal = false
    var runningFlow = false
    var runLog: [String] = []

    var selectedEntry: FlowEntry? {
        flows.first { $0.url == selectedFlowID }
    }

    // MARK: - ライブ操作

    var screenshot: NSImage?
    var screenSize: FTRect?
    var elements: [ElementInfo] = []
    var liveBusy = false
    var liveError: String?
    var bundleID = "com.example.sampleapp"

    // MARK: - FM 探索

    var exploreGoal = ""
    var exploreBundleID = "com.example.sampleapp"
    var exploreMaxSteps = 25
    var exploreLog: [String] = []
    var exploring = false
    private var exploreTask: Task<Void, Never>?

    let fmReport = FMDoctor.check()

    // MARK: - ドライバ

    func makeDriver(overriding platformOverride: String? = nil) throws -> AppDriver {
        switch platformOverride ?? platform {
        case "android":
            return try AndroidDriver(serial: serial.isEmpty ? nil : serial)
        default:
            return BridgeClient(port: UInt16(portText) ?? BridgeAPI.defaultPort)
        }
    }

    func checkConnection() async {
        do {
            let status = try await makeDriver().status()
            connectionStatus = "\(status.device)(\(status.osVersion))"
            connected = status.ready
        } catch {
            connectionStatus = "接続できません — iOS: bridge up / Android: adb devices を確認"
            connected = false
        }
    }

    // MARK: - フロー

    func refreshFlows() {
        let dir = URL(fileURLWithPath: "flows")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let states = Dictionary(uniqueKeysWithValues: flows.map { ($0.url, $0.state) })
        flows = files
            .filter { $0.pathExtension == "yaml" || $0.pathExtension == "yml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                (try? FlowIO.load(from: url)).map {
                    FlowEntry(url: url, flow: $0, state: states[url] ?? .idle)
                }
            }
    }

    private func setState(_ url: URL, _ state: RunState) {
        guard let index = flows.firstIndex(where: { $0.url == url }) else { return }
        flows[index].state = state
    }

    func runSelected() async {
        guard let entry = selectedEntry else { return }
        await run(entry: entry)
    }

    func runAll() async {
        for entry in flows {
            await run(entry: entry)
        }
    }

    func run(entry: FlowEntry) async {
        guard !runningFlow else { return }
        runningFlow = true
        setState(entry.url, .running)
        runLog.append("▶ \(entry.url.lastPathComponent) [\(entry.flow.platform ?? platform)]")
        if entry.flow.dirty == true {
            runLog.append("  ⚠️ dirty(要レビュー)状態のフローです")
        }

        do {
            let driver = try makeDriver(overriding: entry.flow.platform)
            let delegate: FMReplayDelegate? = fmReport.available ? FMReplayDelegate() : nil
            let replayer = Replayer(driver: driver, delegate: delegate, healingEnabled: heal)
            replayer.onStep = { [weak self] step in
                Task { @MainActor in
                    self?.runLog.append(Self.line(for: step))
                }
            }
            let result = await replayer.run(flow: entry.flow)

            if let healedFlow = result.healedFlow, heal {
                try? FlowIO.save(healedFlow, to: entry.url)
                runLog.append("  🔧 修復したロケータでフローを更新しました(dirty)")
            }
            if result.passed {
                runLog.append("→ ✅ 成功")
                setState(entry.url, .passed)
            } else {
                if let triage = result.triage {
                    runLog.append("  🔍 [\(triage.failureClass)] \(triage.summary)")
                }
                if let report = try? ReportWriter.write(result: result,
                                                        to: URL(fileURLWithPath: "reports")) {
                    runLog.append("→ ❌ 失敗 — レポート: \(report.path)")
                } else {
                    runLog.append("→ ❌ 失敗")
                }
                setState(entry.url, .failed)
            }
        } catch {
            runLog.append("→ ❌ エラー: \(error.localizedDescription)")
            setState(entry.url, .failed)
        }
        runLog.append("")
        runningFlow = false
    }

    static func line(for step: StepResult) -> String {
        switch step.status {
        case .passed:
            return "  ✅ \(step.index). \(step.description)"
        case .passedViaFallback(let locator):
            return "  ✅ \(step.index). \(step.description)(フォールバック \(locator.summary))"
        case .healed(let locator):
            return "  🔧 \(step.index). \(step.description) → 自己修復: \(locator.summary)"
        case .failed(let reason):
            return "  ❌ \(step.index). \(step.description) — \(reason)"
        case .skipped(let reason):
            return "  ⚠️ \(step.index). \(step.description)(スキップ: \(reason))"
        }
    }

    // MARK: - ライブ操作

    func refreshLive() async {
        liveBusy = true
        liveError = nil
        do {
            let driver = try makeDriver()
            let png = try await driver.screenshot()
            screenshot = NSImage(data: png)
            let snap = try await driver.snapshot()
            elements = snap.elements
            screenSize = snap.screen
        } catch {
            liveError = error.localizedDescription
        }
        liveBusy = false
    }

    private func liveAction(_ body: @escaping (AppDriver) async throws -> Void) async {
        liveBusy = true
        liveError = nil
        do {
            let driver = try makeDriver()
            try await body(driver)
            try? await Task.sleep(nanoseconds: 700_000_000)
        } catch {
            liveError = error.localizedDescription
        }
        liveBusy = false
        await refreshLive()
    }

    func tap(ref: Int) async {
        await liveAction { try await $0.tap(ref: ref) }
    }

    func tap(x: Double, y: Double) async {
        await liveAction { try await $0.tap(x: x, y: y) }
    }

    func swipe(_ direction: FTSwipeDirection) async {
        await liveAction { try await $0.swipe(direction) }
    }

    func launchApp() async {
        let id = bundleID
        await liveAction { try await $0.launch(bundleID: id) }
    }

    func terminateApp() async {
        await liveAction { try await $0.terminate() }
    }

    // MARK: - FM 探索

    func startExplore() {
        guard !exploring, !exploreGoal.isEmpty, !exploreBundleID.isEmpty else { return }
        exploring = true
        exploreLog = ["🧭 探索開始: \(exploreBundleID)", "   目標: \(exploreGoal)"]

        let goal = exploreGoal
        let bundle = exploreBundleID
        let maxSteps = exploreMaxSteps
        let flowPlatform = platform

        exploreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let driver = try self.makeDriver()
                let agent = ExplorerAgent(driver: driver, goal: goal, maxSteps: maxSteps)
                agent.onStep = { [weak self] step, desc in
                    Task { @MainActor in
                        self?.exploreLog.append(step == 0 ? "🗺 \(desc)" : "[\(step)/\(maxSteps)] \(desc)")
                    }
                }
                let result = try await agent.explore(bundleID: bundle)

                var flow = result.flow
                flow.platform = flowPlatform
                let dir = URL(fileURLWithPath: "flows")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(FlowIO.suggestedFileName(for: flow))
                try FlowIO.save(flow, to: url)

                switch result.outcome {
                case .completed(let desc):
                    self.exploreLog.append("✅ 目標達成(\(result.stepsTaken)ステップ)"
                                           + (desc.map { " — \($0)" } ?? ""))
                case .gaveUp(let reason):
                    self.exploreLog.append("⚠️ 中断: \(reason)(dirty 付きで保存)")
                case .stepLimitReached:
                    self.exploreLog.append("⚠️ ステップ上限に到達(dirty 付きで保存)")
                }
                self.exploreLog.append("📄 保存: \(url.lastPathComponent)")
                self.refreshFlows()
            } catch is CancellationError {
                self.exploreLog.append("⛔️ キャンセルしました")
            } catch {
                self.exploreLog.append("❌ エラー: \(error.localizedDescription)")
            }
            self.exploring = false
        }
    }

    func cancelExplore() {
        exploreTask?.cancel()
    }
}
