// ScenarioHost.swift
// ftester-scenarios(シナリオランナー)をサブプロセスとして起動するホスト側クライアント。
// CLI / GUI / MCP はこれを通してシナリオの一覧取得・実行を行う。
// サブプロセス方式の利点: シナリオのコンパイルエラー/クラッシュがホストを巻き添えにしない、
// ホスト常駐中も再ビルドだけで反映、1シナリオ1プロセスの分離。

import Foundation

/// シナリオのメタデータ(ftester-scenarios list --json の1エントリ)
public struct ScenarioInfo: Codable, Sendable, Hashable {
    /// クラス名.メソッド名
    public let id: String
    public let title: String
    public let app: String
    /// "ios" / "android" / nil(両OS対応)
    public let platform: String?

    public init(id: String, title: String, app: String, platform: String?) {
        self.id = id
        self.title = title
        self.app = app
        self.platform = platform
    }
}

/// シナリオのサブプロセスへ渡すドライバ接続情報
public struct DriverConnection: Sendable, Hashable {
    public let platform: String
    public let port: UInt16?
    public let serial: String?

    public init(platform: String, port: UInt16? = nil, serial: String? = nil) {
        self.platform = platform
        self.port = port
        self.serial = serial
    }
}

public enum ScenarioHostError: Error, LocalizedError {
    case runnerNotFound(product: String)
    case buildFailed(String)
    case listFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runnerNotFound(let product):
            return "\(product) が見つかりません(swift build --product \(product) を実行してください)"
        case .buildFailed(let log):
            return "シナリオのビルドに失敗しました:\n\(log)"
        case .listFailed(let detail):
            return "シナリオ一覧を取得できません: \(detail)"
        }
    }
}

public enum ScenarioHost {

    /// テストプロジェクトを解決する。name 省略時:
    /// Projects/ が 1 つならそれ → LocalConfig.defaultProject → 候補一覧付きエラー
    public static func project(named name: String? = nil) throws -> TestProject {
        guard let root = packageRoot() else {
            throw ScenarioHostError.buildFailed(
                "Package.swift が見つかりません(リポジトリ内で実行してください)")
        }
        return try ProjectStore.find(name, repoRoot: root,
                                     defaultProject: LocalConfig.load().defaultProject)
    }

    /// プロジェクトのシナリオをビルドする。ホスト側で 1 回だけ呼び、サブプロセスは自らビルドしない
    /// (並列ワーカーが同時に swift build して SPM ロック競合するのを防ぐ)
    public static func build(project: TestProject) throws {
        guard let root = packageRoot() else {
            throw ScenarioHostError.buildFailed("Package.swift が見つかりません(リポジトリ内で実行してください)")
        }
        let result = try Shell.run(["swift", "build", "--product", project.productName], cwd: root)
        guard result.status == 0 else {
            throw ScenarioHostError.buildFailed(result.tail)
        }
    }

    /// ランナー実行ファイルの場所: 自 executable と同ディレクトリ → swift build --show-bin-path
    public static func runnerURL(project: TestProject) throws -> URL {
        if let sibling = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent(project.productName),
           FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        if let root = packageRoot(),
           let result = try? Shell.run(["swift", "build", "--show-bin-path"], cwd: root),
           result.status == 0 {
            let binPath = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? ""
            let url = URL(fileURLWithPath: binPath).appendingPathComponent(project.productName)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw ScenarioHostError.runnerNotFound(product: project.productName)
    }

    /// シナリオ一覧を取得する
    public static func list(project: TestProject) throws -> [ScenarioInfo] {
        let runner = try runnerURL(project: project)
        let result = try Shell.run([runner.path, "list", "--json"])
        guard result.status == 0 else {
            throw ScenarioHostError.listFailed(result.tail)
        }
        // ビルドログ等が混ざっても最後の JSON 行だけ読む
        guard let jsonLine = result.output.split(separator: "\n")
            .last(where: { $0.hasPrefix("{") }),
              let data = jsonLine.data(using: .utf8) else {
            throw ScenarioHostError.listFailed("JSON がありません: \(result.tail)")
        }
        struct ListResponse: Codable { let scenarios: [ScenarioInfo] }
        return try JSONDecoder().decode(ListResponse.self, from: data).scenarios
    }

    /// シナリオを 1 つ実行し、NDJSON イベントを onEvent へ流す。戻り値: passed
    @discardableResult
    public static func run(project: TestProject, scenarioID: String,
                           connection: DriverConnection,
                           heal: Bool, reportDir: String, defaultTimeout: Int? = nil,
                           onEvent: @escaping (ScenarioEvent) -> Void) async -> Bool {
        let runner: URL
        do {
            runner = try runnerURL(project: project)
        } catch {
            onEvent(.log("❌ \(error.localizedDescription)"))
            return false
        }

        let process = Process()
        process.executableURL = runner
        var args = ["run", "--scenario", scenarioID,
                    "--platform", connection.platform,
                    "--report-dir", reportDir, "--json",
                    "--project-dir", project.rootURL.path]
        if heal { args.append("--heal") }
        if let port = connection.port { args += ["--port", String(port)] }
        if let serial = connection.serial { args += ["--serial", serial] }
        if let defaultTimeout { args += ["--default-timeout", String(defaultTimeout)] }
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            onEvent(.log("❌ ランナーを起動できません: \(error.localizedDescription)"))
            return false
        }

        // stderr は並行して読む(パイプ詰まりによるサブプロセスのブロック防止)
        let stderrTask = Task.detached { () -> [String] in
            var lines: [String] = []
            for try await line in stderr.fileHandleForReading.bytes.lines {
                lines.append(line)
            }
            return lines
        }

        var passed: Bool?
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                if let event = ScenarioEvent.decode(line: line) {
                    if event.kind == "scenarioFinished" { passed = event.passed }
                    onEvent(event)
                } else if !line.isEmpty {
                    // ユーザーコードの print 等、JSON でない行はログとして取り込む
                    onEvent(.log(line))
                }
            }
        } catch {
            onEvent(.log("⚠️ 出力の読み取りエラー: \(error.localizedDescription)"))
        }

        process.waitUntilExit()
        if let errLines = try? await stderrTask.value, !errLines.isEmpty {
            for line in errLines where !line.isEmpty { onEvent(.log("⚠️ \(line)")) }
        }
        // scenarioFinished が来なかった場合(クラッシュ等)は exit code で判定
        return passed ?? (process.terminationStatus == 0)
    }

    /// カレントディレクトリから上に辿って Package.swift を持つディレクトリを探す
    public static func packageRoot() -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

public extension ScenarioEvent {
    static func log(_ message: String) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "log")
        event.message = message
        return event
    }
}

/// ScenarioEvent → 人間可読な行(ランナーの通常出力と MCP 応答が共用する)
public enum ScenarioLogFormatter {
    public static func lines(for event: ScenarioEvent) -> [String] {
        switch event.kind {
        case "scenarioStarted":
            let title = (event.title?.isEmpty == false) ? " — \(event.title!)" : ""
            return ["▶ \(event.scenario ?? "")\(title)"]
        case "sceneStarted":
            let title = (event.sceneTitle?.isEmpty == false) ? ": \(event.sceneTitle!)" : ""
            return ["  scene \(event.scene ?? 0)\(title)"]
        case "step":
            let index = event.index ?? 0
            let section = event.section.map { "[\($0)] " } ?? ""
            let description = event.description ?? ""
            switch event.status {
            case "passed":
                return ["    ✅ \(index). \(section)\(description)"]
            case "passedViaFallback":
                return ["    ✅ \(index). \(section)\(description)(\(event.detail ?? ""))"]
            case "healed":
                return ["    🔧 \(index). \(section)\(description) → \(event.detail ?? "")"]
            case "failed":
                return ["    ❌ \(index). \(section)\(description)",
                        "       \(event.detail ?? "")"]
            default:
                return ["    ⚠️ \(index). \(section)\(description)(スキップ: \(event.detail ?? ""))"]
            }
        case "sceneFinished":
            return []
        case "fixSuggestion":
            return ["    💡 修正提案: \(event.detail ?? "")"]
        case "scenarioFinished":
            var lines = [event.passed == true ? "  → ✅ 成功" : "  → ❌ 失敗"]
            if let report = event.reportPath { lines.append("  → レポート: \(report)") }
            return lines
        case "log":
            return [event.message ?? ""]
        default:
            return []
        }
    }
}
