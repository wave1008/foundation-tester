// ScenarioHost.swift
// ftester-scenarios(シナリオランナー)をサブプロセスとして起動するホスト側クライアント。
// CLI / MCP はこれを通してシナリオの一覧取得・実行を行う。
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
    /// @Deleted(論理削除)。一覧に残るが一括実行から除外される
    public let deleted: Bool

    public init(id: String, title: String, app: String, platform: String?,
                deleted: Bool = false) {
        self.id = id
        self.title = title
        self.app = app
        self.platform = platform
        self.deleted = deleted
    }

    // deleted キーを出さない旧ランナーの JSON も読めるようにしておく
    private enum CodingKeys: String, CodingKey { case id, title, app, platform, deleted }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        app = try container.decode(String.self, forKey: .app)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// シナリオのサブプロセスへ渡すドライバ接続情報
public struct DriverConnection: Sendable, Hashable {
    public let platform: String
    public let port: UInt16?
    public let serial: String?
    /// iOS 駆動エンジン("inapp"/"hybrid" のときサブプロセスは InAppDriver / Hybrid を使う)
    public let engine: String?
    /// iOS: in-app の simctl 再起動に使うシミュレータ UDID
    public let udid: String?
    /// iOS: engine=hybrid のフォールバック用 XCUITest ブリッジのポート
    public let xcuiPort: UInt16?
    /// iOS: provision 時に in-app ブリッジを注入したアプリの bundleID(engine=inapp/hybrid のみ)。
    /// アプリが suspend され /status プローブが無応答のとき、注入先を特定して inapp/XCUITest の
    /// ルーティングを正しく決めるために使う(サブプロセスの mismatch 判定を参照)。
    public let inappBundleID: String?
    /// 実行プロファイル上のデバイス論理名(profiles/machines/ の name)。レポートヘッダ表示用
    /// (ProfileWorkerFactory/MCPServer のプロファイル経路で設定される。--ports 直指定等では nil)
    public let deviceName: String?

    public init(platform: String, port: UInt16? = nil, serial: String? = nil,
                engine: String? = nil, udid: String? = nil, xcuiPort: UInt16? = nil,
                inappBundleID: String? = nil, deviceName: String? = nil) {
        self.platform = platform
        self.port = port
        self.serial = serial
        self.engine = engine
        self.udid = udid
        self.xcuiPort = xcuiPort
        self.inappBundleID = inappBundleID
        self.deviceName = deviceName
    }
}

public enum ScenarioHostError: Error, LocalizedError {
    case runnerNotFound(product: String)
    case buildFailed(String)
    case listFailed(String)
    case dryRunFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runnerNotFound(let product):
            return "\(product) が見つかりません(swift build --product \(product) を実行してください)"
        case .buildFailed(let log):
            return "シナリオのビルドに失敗しました:\n\(log)"
        case .listFailed(let detail):
            return "シナリオ一覧を取得できません: \(detail)"
        case .dryRunFailed(let detail):
            return "ステップ一覧を取得できません: \(detail)"
        }
    }
}

public enum ScenarioHost {

    /// scenarioTimeout(ホスト側 watchdog)の既定秒。profile にも CLI にも未指定なら使う。
    /// この値は子には渡さない(--default-timeout=子内部の検証待ちとは別物)
    public static let defaultScenarioTimeout = 90

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
    /// (並列ワーカーが同時に swift build して SPM ロック競合するのを防ぐ)。
    /// no-op の swift build でも ~2.6s かかるため、BuildFingerprint が前回ビルド時と一致し
    /// (mtime+size 比較。コンテンツ hash ではない)、かつバイナリが実在すればビルドをスキップする
    public static func build(project: TestProject, log: ((String) -> Void)? = nil) throws {
        guard let root = packageRoot() else {
            throw ScenarioHostError.buildFailed("Package.swift が見つかりません(リポジトリ内で実行してください)")
        }

        let fingerprint = BuildFingerprint.compute(repoRoot: root, scenariosDir: project.scenariosDir)
        if let fingerprint,
           fingerprint == BuildFingerprint.stored(productName: project.productName, repoRoot: root),
           (try? runnerURL(project: project)) != nil {
            log?("→ 変更なし・シナリオビルドをスキップ")
            return
        }

        let result = try Shell.run(["swift", "build", "--product", project.productName], cwd: root)
        guard result.status == 0 else {
            throw ScenarioHostError.buildFailed(result.tail)
        }
        if let fingerprint {
            BuildFingerprint.store(fingerprint, productName: project.productName, repoRoot: root)
        }
    }

    /// ランナー実行ファイルの場所: 自 executable と同ディレクトリ → .build/debug →
    /// swift build --show-bin-path。.build/debug の直接参照は近道であると同時に、
    /// swift test 実行中(SPM ビルドロック保持中)に swift build を呼んでデッドロックするのを
    /// 避けるため(XCTest からも ScenarioHost.run を使えるように)
    public static func runnerURL(project: TestProject) throws -> URL {
        if let sibling = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent(project.productName),
           FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        if let root = packageRoot() {
            let debugBinary = root.appendingPathComponent(".build/debug")
                .appendingPathComponent(project.productName)
            if FileManager.default.isExecutableFile(atPath: debugBinary.path) {
                return debugBinary
            }
            if let result = try? Shell.run(["swift", "build", "--show-bin-path"], cwd: root),
               result.status == 0 {
                let binPath = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n").last.map(String.init) ?? ""
                let url = URL(fileURLWithPath: binPath).appendingPathComponent(project.productName)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
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

    /// シナリオを 1 つ実行し、NDJSON イベントを onEvent へ流す。戻り値: passed。
    /// debug 指定時はランナーを制御チャネル付き(--debug)で起動し、
    /// 起動直後に onControl で続行・ステップ・停止の送り口を渡す
    @discardableResult
    public static func run(project: TestProject, scenarioID: String,
                           connection: DriverConnection,
                           heal: Bool, reportDir: String, defaultTimeout: Int? = nil,
                           scenarioTimeout: Int? = nil,
                           dryRun: Bool = false,
                           debug: ScenarioDebugOptions? = nil,
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
        if dryRun { args.append("--dry-run") }
        if let port = connection.port { args += ["--port", String(port)] }
        if let serial = connection.serial { args += ["--serial", serial] }
        if let engine = connection.engine { args += ["--engine", engine] }
        if let udid = connection.udid { args += ["--udid", udid] }
        if let xcuiPort = connection.xcuiPort { args += ["--xcui-port", String(xcuiPort)] }
        if let inappBundleID = connection.inappBundleID { args += ["--inapp-app", inappBundleID] }
        if let deviceName = connection.deviceName { args += ["--device-name", deviceName] }
        if let defaultTimeout { args += ["--default-timeout", String(defaultTimeout)] }
        if let debug {
            args.append("--debug")
            if debug.pauseOnStart { args.append("--pause-on-start") }
            for location in debug.breakpoints { args += ["--breakpoint", location] }
        }
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        var stdinPipe: Pipe?
        if debug != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        }

        do {
            try process.run()
        } catch {
            onEvent(.log("❌ ランナーを起動できません: \(error.localizedDescription)"))
            return false
        }
        if let debug, let stdinPipe {
            debug.onControl(ScenarioRunControl(handle: stdinPipe.fileHandleForWriting))
        }

        // scenarioTimeout はホスト側の壁時計 watchdog 専用で子には渡さない。debug 中は人間が
        // ブレークで止めるため無効化する。発火時は SIGTERM→2s 猶予→SIGKILL で子を落とし、
        // stdout の EOF で下の for-await が自然終了する経路に合流させる(ループ本体は変えない)。
        let watchdogSeconds: Int? = (debug == nil)
            ? (scenarioTimeout ?? defaultScenarioTimeout) : nil
        let timeoutGuard = TimeoutGuard()
        var killer: Task<Void, Never>?
        if let watchdogSeconds {
            killer = Task {
                try? await Task.sleep(nanoseconds: UInt64(watchdogSeconds) * 1_000_000_000)
                guard !Task.isCancelled, await timeoutGuard.claim() else { return }
                process.terminate()  // SIGTERM
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s 猶予
                // process.isRunning は内部で waitpid して子を reap してしまい、下の
                // waitUntilExit() が終了通知を取りこぼして永久ハングする(SIGTERM を無視した
                // 子で実測: run 全体が凍結)。kill(pid, 0) は reap せず生存確認だけ行う。
                if kill(process.processIdentifier, 0) == 0 { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }

        // stderr は並行して読む(パイプ詰まりによるサブプロセスのブロック防止)
        let stderrTask = Task.detached { () -> [String] in
            var lines: [String] = []
            for await line in lineStream(stderr.fileHandleForReading) {
                lines.append(line)
            }
            return lines
        }

        // 注意: FileHandle.bytes.lines は使わない。パイプではプロセス終了(EOF)まで
        // 行がまとめて届くことがあり、一時停止中の paused イベントがホストへ届かず
        // デバッグ実行が相互待ちになる(ScenarioHostDebugTests で回帰検知)
        var passed: Bool?
        for await line in lineStream(stdout.fileHandleForReading) {
            if let event = ScenarioEvent.decode(line: line) {
                if event.kind == "scenarioFinished" { passed = event.passed }
                onEvent(event)
            } else if !line.isEmpty {
                // ユーザーコードの print 等、JSON でない行はログとして取り込む
                onEvent(.log(line))
            }
        }

        process.waitUntilExit()
        try? stdinPipe?.fileHandleForWriting.close()

        // watchdog と正常終了のどちらが先に claim したかで timeout を確定する。cancel は
        // waitUntilExit の後で行う: SIGTERM を子が無視する場合、killer の 2s 猶予後の SIGKILL が
        // 唯一の脱出路なので、子の死を待つ前に killer を止めてはならない。
        var timedOut = false
        if let killer {
            timedOut = !(await timeoutGuard.claim())
            killer.cancel()
        }

        let errLines = await stderrTask.value
        for line in errLines where !line.isEmpty { onEvent(.log("⚠️ \(line)")) }

        // タイムアウト時は子がレポートも scenarioFinished も出さずに死ぬ。失敗可視化の契約:
        // 合成 scenarioFinished(passed:false) を onEvent で流し、通常失敗と同じ経路で集計・
        // モニタ表示させる(戻り値も false)。レポート(.md)は子専管のため書かない=クラッシュ相当。
        if timedOut, let watchdogSeconds {
            onEvent(.log("⏱ シナリオが \(watchdogSeconds)s を超過したため強制終了しました"))
            var finished = ScenarioEvent(kind: "scenarioFinished")
            finished.scenario = scenarioID
            finished.passed = false
            onEvent(finished)
            if !dryRun { LastResultsStore.record(project: project, scenarioID: scenarioID, passed: false) }
            return false
        }
        // scenarioFinished が来なかった場合(クラッシュ等)は exit code で判定
        let result = passed ?? (process.terminationStatus == 0)
        // dry-run は実機能を動かしていないため直近結果を上書きしない(実失敗を消さない)
        if !dryRun { LastResultsStore.record(project: project, scenarioID: scenarioID, passed: result) }
        return result
    }

    /// シナリオを dry-run(No-Load-Run)してイベント列を収集する。デバイス不要・FM 不使用で
    /// 全コマンドが step イベントとして列挙される(ステップ一覧表示用)。
    /// dry-run でもランナーはレポートを書くため、一時ディレクトリに書かせて後始末する
    public static func dryRunSteps(project: TestProject,
                                   scenarioID: String) async throws -> [ScenarioEvent] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var events: [ScenarioEvent] = []
        // dry-run は NullDriver 固定のため接続情報は使われない(platform はダミー)
        let passed = await run(project: project, scenarioID: scenarioID,
                               connection: DriverConnection(platform: "ios"),
                               heal: false, reportDir: tempDir.path,
                               dryRun: true) { events.append($0) }
        guard passed else {
            let detail = events.compactMap(\.message).suffix(5).joined(separator: "\n")
            throw ScenarioHostError.dryRunFailed(detail.isEmpty ? "dry-run が失敗しました" : detail)
        }
        return events
    }

    /// FileHandle を行単位の AsyncStream にする。readabilityHandler ベースで
    /// データ到着ごとに行を切り出して即時配信する(改行が来るまでの端数はバッファ)。
    /// EOF(空 Data)で残りを流して終了する
    static func lineStream(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            // readabilityHandler は FileHandle 内部のキューで直列に呼ばれる
            var buffer = Data()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {  // EOF
                    handle.readabilityHandler = nil
                    if !buffer.isEmpty {
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                        buffer.removeAll()
                    }
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline],
                                      as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
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

/// watchdog の kill と子の正常終了が競合したとき、先に claim した側だけが勝つ 1 回限りフラグ
/// (kill 発火と cancel のレースで二重処理しないため)
private actor TimeoutGuard {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
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
        case "paused":
            return ["    ⏸ \(event.index ?? 0). \(event.description ?? "") の手前で一時停止中"]
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
