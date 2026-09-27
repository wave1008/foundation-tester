// DoctorBundle.swift
// `fleetest doctor --bundle` が集める診断一式の選定・zip 化。
//
// **選定(何を集めるか)は純粋関数**(実ファイルの列挙だけで外部コマンドを撃たない)にして
// DoctorBundleTests が一時フォルダで検証する。外部コマンドを撃つのは versionsText / captureDoctorOutput /
// build の zip 化(ditto)だけ。
//
// 同梱するのはログとバージョン情報だけで、**どこへも送信しない**(呼び出し元 = DoctorCommand が
// その一言も出す)。

import FTAndroid
import FTBridgeClient
import FTCore
import Foundation

enum DoctorBundle {

    /// バンドルに集める1件。`archivePath` は zip 内(= 集約フォルダ内)の相対パス、
    /// `sourceURL` は元ファイルの絶対パス(manifest.txt に「元パス」として書く。`exists` が false でも
    /// 「どこを探したか」を書けるよう保つ)。`exists` が false のものはコピーせず manifest に "missing" と書く
    /// (欄ごと省く。「その他」に丸めない)
    struct Entry {
        let archivePath: String
        let sourceURL: URL
        let exists: Bool
    }

    struct BuildResult {
        let zipURL: URL
        let sizeBytes: Int64
    }

    enum BundleError: Error, LocalizedError {
        case zipFailed(status: Int32, detail: String)
        var errorDescription: String? {
            switch self {
            case .zipFailed(let status, let detail):
                return "ditto exited \(status): \(detail)"
            }
        }
    }

    // MARK: - 選定(純粋関数)

    /// `bridge-<port>.log` / `bridge-<port>.prev.log` / `bridge-build-<port>.log`(全ポート・
    /// 全プレフィックス共通のパターン)。定義元は `BridgeLauncher.logPath` / `prevLogPath` /
    /// `writeBuildLog`(いずれも `bridge-` 始まり `.log` 終わり)
    static func bridgeLogEntries(stateDir: URL) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
        return names
            .filter { $0.hasPrefix("bridge-") && $0.hasSuffix(".log") }
            .sorted()
            .map { Entry(archivePath: "logs/\($0)", sourceURL: stateDir.appendingPathComponent($0), exists: true) }
    }

    /// `~/Library/Logs/fleetest/emulator/*.log`(`*.prev.log` も同じ `.log` 終わりなので1つの
    /// フィルタで拾える。定義元は `EmulatorLog.url(avdID:)` / `EmulatorLog.swift` の prev 命名)
    static func emulatorLogEntries(directory: URL) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".log") }
            .sorted()
            .map { Entry(archivePath: "emulator/\($0)", sourceURL: directory.appendingPathComponent($0), exists: true) }
    }

    /// `install-<日時>.log` の最新1本(ファイル名が `install-YYYYMMDD-HHMMSS.log` で
    /// 辞書順=時系列なので、辞書順最大が最新)。無ければ missing の1件を返す
    static func latestInstallLogEntry(stateDir: URL) -> Entry {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
        let latest = names.filter { $0.hasPrefix("install-") && $0.hasSuffix(".log") }.sorted().last
        guard let latest else {
            return Entry(archivePath: "logs/install-latest.log",
                        sourceURL: stateDir.appendingPathComponent("install-*.log"), exists: false)
        }
        return Entry(archivePath: "logs/\(latest)", sourceURL: stateDir.appendingPathComponent(latest), exists: true)
    }

    private static func namedFileEntry(directory: URL, name: String, archivePath: String) -> Entry {
        let url = directory.appendingPathComponent(name)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        return Entry(archivePath: archivePath, sourceURL: url, exists: exists)
    }

    private static func directoryEntry(directory: URL, name: String, archivePath: String) -> Entry {
        let url = directory.appendingPathComponent(name)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        return Entry(archivePath: archivePath, sourceURL: url, exists: exists)
    }

    /// `<repoRoot>/.fleetest/cleanup.log`(RunCompletionSweep.logName と同じ名前)
    static func cleanupLogEntry(stateDir: URL) -> Entry {
        namedFileEntry(directory: stateDir, name: "cleanup.log", archivePath: "logs/cleanup.log")
    }

    /// `~/Library/Logs/fleetest/emulator/metal-history.ndjson`(定義元 FTAndroid/MetalErrorHistory.swift)
    static func metalHistoryEntry(directory: URL) -> Entry {
        namedFileEntry(directory: directory, name: "metal-history.ndjson", archivePath: "emulator/metal-history.ndjson")
    }

    /// 直近 n 件の runID(新しい順)。runID の先頭はタイムスタンプなので**ディレクトリ名の辞書順降順 =
    /// 新しい順**(`RunResultsStore.scanRecords` の maxRuns 選定と同じ前提)。run.json の中身は読まない
    /// —— 壊れた run.json も診断の対象なので、decode できるかで選別しない
    static func recentRunIDs(resultsDir: URL, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let runsDir = resultsDir.appendingPathComponent("runs")
        guard let monthDirs = try? FileManager.default.contentsOfDirectory(
            at: runsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var runIDs: [String] = []
        for monthDir in monthDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: monthDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            runIDs += entries.map(\.lastPathComponent)
        }
        return Array(runIDs.sorted(by: >).prefix(count))
    }

    /// 1 run 分: `run.json` / `scenarios/` / `events/`(退避された旧イベントログ
    /// `events/superseded/` を含めてディレクトリ丸ごと)/ `superseded/`(discardLast で退避した
    /// 旧シナリオ記録。`RunResultsStore.supersedeScenario` の置き場。`scenarios/` の隣で
    /// `events/superseded/` とは別物)/ `host-metrics.ndjson`。
    /// **`recordings/` は意図的に含めない**(大きいため)
    static func runEntries(resultsDir: URL, runID: String) -> [Entry] {
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        let prefix = "runs/\(runID)/"
        return [
            namedFileEntry(directory: runDir, name: "run.json", archivePath: prefix + "run.json"),
            directoryEntry(directory: runDir, name: "scenarios", archivePath: prefix + "scenarios"),
            directoryEntry(directory: runDir, name: "events", archivePath: prefix + "events"),
            directoryEntry(directory: runDir, name: "superseded", archivePath: prefix + "superseded"),
            namedFileEntry(directory: runDir, name: "host-metrics.ndjson", archivePath: prefix + "host-metrics.ndjson"),
        ]
    }

    // MARK: - manifest

    private static func fileOrDirectorySize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return Int64((attrs?[.size] as? Int) ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 各エントリ1行: `<archivePath>\t<元パス>\t<size> bytes\t<mtime ISO8601>` /
    /// missing は `<archivePath>\t<元パス>\tmissing`(欄は省かず、探した場所は残す)
    static func manifestLines(_ entries: [Entry]) -> [String] {
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            guard entry.exists else { return "\(entry.archivePath)\t\(entry.sourceURL.path)\tmissing" }
            let size = fileOrDirectorySize(entry.sourceURL)
            let mtime = modificationDate(entry.sourceURL).map { formatter.string(from: $0) } ?? "unknown"
            return "\(entry.archivePath)\t\(entry.sourceURL.path)\t\(size) bytes\t\(mtime)"
        }
    }

    // MARK: - バージョン情報・doctor 本体の出力(外部コマンドを撃つ)

    static func versionsText(toolRoot: URL) -> String {
        var lines: [String] = []
        if let result = try? Shell.run(["git", "-C", toolRoot.path, "rev-parse", "HEAD"]),
           let head = result.outputIfSucceeded?.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.append("fleetest commit: \(head)")
        } else {
            lines.append("fleetest commit: missing (git rev-parse failed)")
        }
        if let result = try? Shell.run(["git", "-C", toolRoot.path, "status", "--porcelain"]),
           let out = result.outputIfSucceeded {
            let count = out.split(separator: "\n").count
            lines.append("uncommitted changes: \(count) file(s)")
        } else {
            lines.append("uncommitted changes: missing (git status failed)")
        }
        lines.append("fleetest api protocol version: \(fleetestProtocolVersion)")
        lines.append("iOS bridge protocol version: \(BridgeAPI.bridgeProtocolVersion)")
        lines.append("Android bridge version code: \(AndroidDriver.expectedBridgeVersionCode)")
        if let result = try? Shell.run(["sw_vers"]), let out = result.outputIfSucceeded {
            lines.append("sw_vers:\n" + out.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            lines.append("sw_vers: missing")
        }
        if let result = try? Shell.run(["xcodebuild", "-version"]), let out = result.outputIfSucceeded {
            lines.append("xcodebuild -version:\n" + out.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            lines.append("xcodebuild -version: missing")
        }
        if let result = try? Shell.run(["adb", "version"]), let out = result.outputIfSucceeded {
            lines.append("adb version:\n" + out.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            lines.append("adb version: missing (adb not found)")
        }
        return lines.joined(separator: "\n\n") + "\n"
    }

    /// 通常の `fleetest doctor` を子プロセスとして再実行し、その出力(stdout+stderr)をそのまま返す。
    /// **成否(exit code)で本文を選ばない** —— 検査が❌を出して非0で終わるのは正常な出力で、
    /// ここは中身をそのまま埋め込むだけ。撃てなければその旨の1行を返す(全体は失敗させない)
    /// **素の `doctor` は撃たない** —— 古いブリッジを止める副作用があり、報告したい状態
    /// (ブリッジとそのログ)を集める前に変えてしまう。ブリッジに触らない2つだけを走らせる
    static func captureDoctorOutput() -> String {
        ["--roots-only", "--fm-only"].map { flag in
            do {
                let result = try Shell.run([FleetRunner.selfBinaryPath(), "doctor", flag], timeout: 180)
                return "$ fleetest doctor \(flag)\nexit code: \(result.status)\n\n" + result.output
            } catch {
                return "$ fleetest doctor \(flag)\n(could not run: \(error.localizedDescription))"
            }
        }.joined(separator: "\n\n")
    }

    // MARK: - 組み立て

    static func build(outputPath: URL, runCount: Int, projectName: String?) throws -> BuildResult {
        let roots = try RetentionSweeper.Roots.resolve()
        let toolStateDir = roots.tool.appendingPathComponent(".fleetest")
        let packageStateDir = roots.package.appendingPathComponent(".fleetest")

        var entries: [Entry] = []
        entries += bridgeLogEntries(stateDir: toolStateDir)
        entries.append(cleanupLogEntry(stateDir: toolStateDir))
        entries.append(latestInstallLogEntry(stateDir: packageStateDir))
        entries += emulatorLogEntries(directory: EmulatorLog.directory)
        entries.append(metalHistoryEntry(directory: EmulatorLog.directory))

        var runNote: String?
        if let project = try? ScenarioHost.project(named: projectName) {
            let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
            let runIDs = recentRunIDs(resultsDir: resultsDir, count: runCount)
            if runIDs.isEmpty {
                runNote = "runs: missing (no run results found for project \(project.name))"
            } else {
                for runID in runIDs { entries += runEntries(resultsDir: resultsDir, runID: runID) }
            }
        } else {
            let suffix = projectName.map { " named \($0)" } ?? ""
            runNote = "runs: missing (could not resolve a test project\(suffix) — run results were not included)"
        }

        let doctorOutput = captureDoctorOutput()
        let versions = versionsText(toolRoot: roots.tool)

        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fleetest-diag-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        for entry in entries where entry.exists {
            let dest = stagingRoot.appendingPathComponent(entry.archivePath)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: entry.sourceURL, to: dest)
        }

        try versions.write(to: stagingRoot.appendingPathComponent("versions.txt"), atomically: true, encoding: .utf8)
        try doctorOutput.write(to: stagingRoot.appendingPathComponent("doctor.txt"), atomically: true, encoding: .utf8)

        var manifest = manifestLines(entries)
        if let runNote { manifest.append(runNote) }
        try (manifest.joined(separator: "\n") + "\n").write(
            to: stagingRoot.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)

        if FileManager.default.fileExists(atPath: outputPath.path) {
            try FileManager.default.removeItem(at: outputPath)
        }
        try FileManager.default.createDirectory(
            at: outputPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 拡張属性・リソースフォークを入れない(入れると受け手の展開先に `._*` が1ファイルごとに並ぶ)
        let zipResult = try Shell.run(["/usr/bin/ditto", "-c", "-k", "--keepParent",
                                       "--norsrc", "--noextattr", "--noacl",
                                       stagingRoot.path, outputPath.path])
        guard zipResult.status == 0 else {
            throw BundleError.zipFailed(status: zipResult.status, detail: zipResult.tail)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath.path)
        let size = Int64((attrs?[.size] as? Int) ?? 0)
        return BuildResult(zipURL: outputPath, sizeBytes: size)
    }
}
