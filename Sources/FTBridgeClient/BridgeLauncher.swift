// xcodebuild build-for-testing / test-without-building によるランナーの起動・停止管理。
// ランナーは「終わらないUIテスト」なので test-without-building は常駐プロセスになる。

import Foundation
import FTCore

public struct BridgeLauncher {
    public let repoRoot: URL
    public let device: String
    public let port: UInt16

    var stateDir: URL { repoRoot.appendingPathComponent(".ftester") }
    var derivedDataPath: URL { stateDir.appendingPathComponent("DerivedData") }
    // ポート別に分離(複数ブリッジ=複数シミュレータの並列運用のため)
    var logPath: URL { stateDir.appendingPathComponent("bridge-\(port).log") }
    var pidPath: URL { stateDir.appendingPathComponent("bridge-\(port).pid") }
    var projectPath: URL { repoRoot.appendingPathComponent("Runner/FTesterRunner.xcodeproj") }

    /// --device には名前("iPhone 17")と UDID のどちらも渡せる
    var destination: String {
        let isUDID = device.count == 36 && device.split(separator: "-").count == 5
        return isUDID ? "platform=iOS Simulator,id=\(device)"
                      : "platform=iOS Simulator,name=\(device)"
    }

    public init(repoRoot: URL, device: String = "iPhone 17 Pro", port: UInt16 = BridgeAPI.defaultPort) {
        self.repoRoot = repoRoot
        self.device = device
        self.port = port
    }

    /// 生成物(.xcodeproj)はコミットしない方針
    public func generateProjectIfNeeded() throws {
        if FileManager.default.fileExists(atPath: projectPath.path) { return }
        let result = try Shell.run(
            ["xcodegen", "generate"],
            cwd: repoRoot.appendingPathComponent("Runner")
        )
        guard result.status == 0 else {
            throw LauncherError.commandFailed("xcodegen generate", result.tail)
        }
    }

    public func buildForTesting() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let result = try Shell.run([
            "xcodebuild", "build-for-testing",
            "-project", projectPath.path,
            "-scheme", "FTesterRunner",
            "-destination", destination,
            "-derivedDataPath", derivedDataPath.path,
        ], cwd: repoRoot)
        guard result.status == 0 else {
            throw LauncherError.commandFailed("xcodebuild build-for-testing", result.tail)
        }
    }

    /// SampleApp をビルドしてシミュレータにインストールする(検証用)
    public func installSampleApp() throws {
        let result = try Shell.run([
            "xcodebuild", "build",
            "-project", projectPath.path,
            "-scheme", "SampleApp",
            "-destination", destination,
            "-derivedDataPath", derivedDataPath.path,
        ], cwd: repoRoot)
        guard result.status == 0 else {
            throw LauncherError.commandFailed("xcodebuild build (SampleApp)", result.tail)
        }
        let appPath = derivedDataPath
            .appendingPathComponent("Build/Products/Debug-iphonesimulator/SampleApp.app")
        let install = try Shell.run(["xcrun", "simctl", "install", "booted", appPath.path], cwd: repoRoot)
        guard install.status == 0 else {
            throw LauncherError.commandFailed("simctl install", install.tail)
        }
    }

    /// FT_PORT はビルド時に 8123 で焼き込まれるため、xctestrun のコピーに指定ポートを注入してから
    /// 起動する(ビルド1回で任意ポート数のブリッジを起動できる)
    public func startDetached() throws {
        killOrphanRunners()
        guard let original = try findXCTestRun() else {
            throw LauncherError.xctestrunNotFound(derivedDataPath.path)
        }
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let xctestrun = try injectPort(into: original)

        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", destination,
        ]
        process.currentDirectoryURL = repoRoot
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        try String(process.processIdentifier).write(to: pidPath, atomically: true, encoding: .utf8)
    }

    func injectPort(into xctestrun: URL) throws -> URL {
        let data = try Data(contentsOf: xctestrun)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] else {
            throw LauncherError.commandFailed("xctestrun parse", xctestrun.path)
        }

        func inject(into target: inout [String: Any]) {
            var env = target["EnvironmentVariables"] as? [String: Any] ?? [:]
            env["FT_PORT"] = String(port)
            target["EnvironmentVariables"] = env
        }

        if var configurations = plist["TestConfigurations"] as? [[String: Any]] {
            // 現行形式(v2): TestConfigurations[].TestTargets[]
            for ci in configurations.indices {
                guard var targets = configurations[ci]["TestTargets"] as? [[String: Any]] else { continue }
                for ti in targets.indices { inject(into: &targets[ti]) }
                configurations[ci]["TestTargets"] = targets
            }
            plist["TestConfigurations"] = configurations
        } else {
            // 旧形式: トップレベルにターゲット辞書が並ぶ
            for (key, value) in plist {
                guard var target = value as? [String: Any], target["TestBundlePath"] != nil else { continue }
                inject(into: &target)
                plist[key] = target
            }
        }

        // __TESTROOT__ は xctestrun ファイルのあるディレクトリ基準で解決されるため、
        // コピーは必ず元ファイルと同じディレクトリ(Build/Products/)に置く
        let output = xctestrun.deletingLastPathComponent()
            .appendingPathComponent("FTesterRunner-\(port).xctestrun")
        let outData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try outData.write(to: output)
        return output
    }

    /// HTTP サーバだけ死んで親 xcodebuild が残留するケースの後始末。起動前に走らせないと
    /// pid ファイルが新プロセスの PID で上書きされ、旧プロセスがどの pid ファイルからも
    /// 参照されない残骸になる。マッチはこのポート専用の xctestrun ファイル名
    /// (FTesterRunner-<port>.xctestrun。ポートごとに別ファイルなので他ポートは誤爆しない)を
    /// コマンドラインに含む xcodebuild のみ対象にする。
    func killOrphanRunners() {
        let xctestrunPath = derivedDataPath
            .appendingPathComponent("Build/Products/FTesterRunner-\(port).xctestrun").path
        guard let ps = try? Shell.run(["ps", "-axo", "pid=,command="]), ps.status == 0 else { return }
        var pids: [Int32] = []
        for line in ps.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let command = trimmed[trimmed.index(after: spaceIdx)...]
            guard command.contains("xcodebuild"), command.contains(xctestrunPath),
                  let pid = Int32(trimmed[..<spaceIdx]) else { continue }
            pids.append(pid)
        }
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        var remaining = Set(pids)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !remaining.isEmpty {
            remaining = remaining.filter { kill($0, 0) == 0 }
            if remaining.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        for pid in remaining { kill(pid, SIGKILL) }
        let message = "→ ポート \(port) の残骸ランナー(pid \(pids.map(String.init).joined(separator: ", "))) を掃除しました\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    public func stop() throws {
        guard let pidString = try? String(contentsOf: pidPath, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LauncherError.notRunning
        }
        kill(pid, SIGTERM)
        try? FileManager.default.removeItem(at: pidPath)
    }

    /// 同一ポートで起動し直す前に旧プロセスの消滅を待つ(stop() は待たないため、直後の
    /// startDetached が旧ブリッジの /status を拾って偽の起動成功になる)
    public func stopAndWait(timeout: TimeInterval = 10) async throws {
        guard let pidString = try? String(contentsOf: pidPath, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LauncherError.notRunning
        }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: pidPath)
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        kill(pid, SIGKILL)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try? FileManager.default.removeItem(at: pidPath)
    }

    /// 指定シミュレータ(UDID)を対象にするブリッジプロセスを pid ファイルから探して全て停止する。
    /// 特定はプロセスの起動引数(-destination ... id=<UDID>)照合。/status 無応答のゾンビ
    /// xcodebuild は HTTP スキャンに映らないがこれなら殺せる(生きた XCUITest セッションを残すと
    /// シミュレータが再ブートされ「停止したのに起動中に戻る」症状になる)。戻り値=停止ポート一覧
    public static func stopMatching(udid: String, repoRoot: URL) -> [String] {
        let stateDir = repoRoot.appendingPathComponent(".ftester")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return [] }
        var stopped: [String] = []
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "pid" {
            guard let pidString = try? String(contentsOf: entry, encoding: .utf8),
                  let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            let ps = try? Shell.run(["ps", "-p", String(pid), "-o", "command="])
            guard let ps, ps.status == 0 else {
                // プロセスが既に死んでいる stale ファイル。残すと assignPort がそのポートを
                // 使用中とみなし続け採番がずれていくため、UDID に関係なくここで掃除する
                try? FileManager.default.removeItem(at: entry)
                continue
            }
            guard ps.output.contains(udid) else { continue }
            kill(pid, SIGTERM)
            try? FileManager.default.removeItem(at: entry)
            stopped.append(entry.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "bridge-", with: ""))
        }
        return stopped.sorted()
    }

    /// .ftester/bridge-*.pid を走査して全ブリッジを停止する。戻り値は停止したポート一覧
    public static func stopAll(repoRoot: URL) -> [String] {
        let stateDir = repoRoot.appendingPathComponent(".ftester")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return [] }
        var stopped: [String] = []
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "pid" {
            if let pidString = try? String(contentsOf: entry, encoding: .utf8),
               let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGTERM)
                stopped.append(entry.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "bridge-", with: ""))
            }
            try? FileManager.default.removeItem(at: entry)
        }
        return stopped
    }

    public func waitUntilReady(timeout: TimeInterval = 180) async throws {
        let client = BridgeClient(port: port)
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                let status = try await client.status()
                if status.ready {
                    enableReduceMotion()
                    return
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw LauncherError.timedOut(lastError.map { "\($0)" } ?? "no response", logPath.path)
    }

    /// コールド起動時のみ実行(稼働中ブリッジの再利用時はここを通らない)。設定は以後起動される
    /// アプリに効く(実行中アプリには効かない。/session がシナリオ毎に再起動するので問題ない)。失敗は非致命。
    private func enableReduceMotion() {
        let result = try? Shell.run([
            "xcrun", "simctl", "spawn", device,
            "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", "true",
        ])
        guard result?.status == 0 else {
            let message = "⚠️ Reduce Motion の有効化に失敗しました(\(device))。"
                + "アニメーションが有効なままだとアクションの整定待ちが遅くなります\n"
            FileHandle.standardError.write(Data(message.utf8))
            return
        }
    }

    func findXCTestRun() throws -> URL? {
        let productsDir = derivedDataPath.appendingPathComponent("Build/Products")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: productsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let candidates = entries.filter {
            $0.pathExtension == "xctestrun"
                && $0.lastPathComponent.contains("FTesterRunner")
                // 自分が生成したポート注入コピー(FTesterRunner-<port>.xctestrun)は除外
                && !($0.lastPathComponent.hasPrefix("FTesterRunner-"))
        }
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }
}

public enum LauncherError: Error, LocalizedError {
    case commandFailed(String, String)
    case xctestrunNotFound(String)
    case notRunning
    case timedOut(String, String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd, let tail):
            return "\(cmd) が失敗しました:\n\(tail)"
        case .xctestrunNotFound(let path):
            return "xctestrun が見つかりません(先に build-for-testing が必要): \(path)"
        case .notRunning:
            return "ブリッジは起動していません(.ftester/bridge.pid なし)"
        case .timedOut(let lastError, let log):
            return "ブリッジの起動がタイムアウトしました(最後のエラー: \(lastError))。ログ: \(log)"
        }
    }
}

public enum RepoRoot {
    /// カレントディレクトリから上に辿って Package.swift + Runner/ を持つディレクトリを探す
    public static func find() throws -> URL {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<10 {
            let hasPackage = FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
            let hasRunner = FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Runner/project.yml").path)
            if hasPackage && hasRunner { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw LauncherError.commandFailed(
            "repo root detection",
            "foundation-tester リポジトリのルート(またはその配下)で実行してください")
    }
}
