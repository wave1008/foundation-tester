// xcodebuild build-for-testing / test-without-building によるランナーの起動・停止管理。
// ランナーは「終わらないUIテスト」なので test-without-building は常駐プロセスになる。

import Foundation
import FTCore

public struct BridgeLauncher {
    public let repoRoot: URL
    public let device: String
    public let port: UInt16
    /// 実機か。シミュレータ UUID の形状推測では実機 UDID を判別できない
    /// (実機は "00008130-000A1B2C3D4E5678" の 25 文字型や旧 40 桁 hex 型があり、
    /// 36 文字・ダッシュ 5 分割の判定を外れて name= に化ける)ため呼び出し側が明示する
    public let physical: Bool

    var stateDir: URL { repoRoot.appendingPathComponent(".fleetest") }
    /// 実機とシミュレータでビルド成果物(Debug-iphoneos / Debug-iphonesimulator)も
    /// xctestrun も別物なので DerivedData ごと分ける(混在すると findXCTestRun が誤った方を掴む)
    var derivedDataPath: URL {
        stateDir.appendingPathComponent(physical ? "DerivedData-device" : "DerivedData")
    }
    // ポート別に分離(複数ブリッジ=複数シミュレータの並列運用のため)
    var logPath: URL { stateDir.appendingPathComponent("bridge-\(port).log") }
    var pidPath: URL { stateDir.appendingPathComponent("bridge-\(port).pid") }
    var projectPath: URL { repoRoot.appendingPathComponent("Runner/FleetestRunner.xcodeproj") }

    /// --device には名前("iPhone 17")と UDID のどちらも渡せる(シミュレータのみ。実機は UDID 必須)
    var destination: String {
        if physical { return "platform=iOS,id=\(device)" }
        let isUDID = device.count == 36 && device.split(separator: "-").count == 5
        return isUDID ? "platform=iOS Simulator,id=\(device)"
                      : "platform=iOS Simulator,name=\(device)"
    }

    /// **`physical` に既定値を置かない** —— 呼び忘れると DerivedData も -destination も
    /// シミュレータ用のまま実機へ向けて起動し、確実に失敗する(2026-08-30 に
    /// LiveBridgeAutoStarter が実際にこれを踏んでいた)。新しい呼び出し元の呼び忘れは
    /// コンパイルで止める(BridgeLauncher.stopAll の skipPhysical と同じ規律)
    public init(repoRoot: URL, device: String = "iPhone 17 Pro",
                port: UInt16 = BridgeAPI.defaultPort, physical: Bool) {
        self.repoRoot = repoRoot
        self.device = device
        self.port = port
        self.physical = physical
    }

    /// 生成物(.xcodeproj)はコミットしない方針。project.yml を編集したら作り直す
    /// (bundle id の変数化・署名設定の追加が反映されないと実機ビルドが旧設定のまま通る)
    public func generateProjectIfNeeded() throws {
        let manifest = repoRoot.appendingPathComponent("Runner/project.yml")
        if FileManager.default.fileExists(atPath: projectPath.path), !isStale(manifest: manifest) {
            return
        }
        let result = try Shell.run(
            ["xcodegen", "generate"],
            cwd: repoRoot.appendingPathComponent("Runner")
        )
        guard result.status == 0 else {
            throw LauncherError.commandFailed("xcodegen generate", result.tail)
        }
    }

    /// project.yml **またはランナーのソース**が .xcodeproj より新しいか
    /// (取得できなければ「古くない」= 再生成しない)。
    ///
    /// **ソース側も見るのが要点**(2026-08-11 に踏んだ): project.yml はディレクトリを指すので、
    /// ランナーへファイルを1本足しても manifest の mtime は動かない。manifest だけを見ていると
    /// **新しいファイルがターゲットに入らないまま**ビルドが走り、`cannot find X in scope` で
    /// 落ちる(原因が project 生成側にあると気付きにくい)
    private func isStale(manifest: URL) -> Bool {
        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        guard let projectDate = modified(projectPath.appendingPathComponent("project.pbxproj")) else {
            return false
        }
        if let manifestDate = modified(manifest), manifestDate > projectDate { return true }
        let sourceDir = repoRoot.appendingPathComponent("Runner/FleetestRunnerUITests")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: sourceDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return contents.contains { (modified($0) ?? .distantPast) > projectDate }
    }

    public func buildForTesting() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let signingArguments = try codeSigningArguments()
        let signing = signingArguments.joined(separator: "\n")
        // 署名設定(チーム・接頭辞)が変わっても増分ビルドは旧 bundle id のランナー .app を
        // 作り直さない。ビルドは成功するのに起動が「The requested application
        // com.example.… is not installed (-10814)」で落ちる(2026-08-31 実害)ので成果物ごと捨てる
        if Self.signingMismatch(
            stored: try? String(contentsOf: signingFingerprintPath, encoding: .utf8),
            current: signing) {
            FileHandle.standardError.write(Data(
                ("[bridge] The code-signing settings (team / bundle id prefix) changed — "
                 + "discarding \(derivedDataPath.lastPathComponent) and rebuilding\n").utf8))
            try? FileManager.default.removeItem(at: derivedDataPath)
        }
        let result = try Shell.run([
            "xcodebuild", "build-for-testing",
            "-project", projectPath.path,
            "-scheme", "FleetestRunner",
            "-destination", destination,
            "-derivedDataPath", derivedDataPath.path,
        ] + signingArguments, cwd: repoRoot)
        guard result.status == 0 else {
            // **署名で止まっているなら「次にやること」を出す** —— 生のビルドログは数十行あり、
            // そのまま拡張のバナーへ流れると読み手は何をすればいいか分からない
            // (XcodeSigningDiagnosis)。当てはまらないログには触らず生のまま出す
            let problems = XcodeSigningDiagnosis.problems(inBuildLog: result.tail)
            if !problems.isEmpty {
                throw LauncherError.codeSigningIncomplete(
                    problems: problems, logPath: writeBuildLog(result.tail)?.path)
            }
            throw LauncherError.commandFailed("xcodebuild build-for-testing", result.tail)
        }
        ToolchainFingerprint.store(at: Self.runnerFingerprintPath(derivedDataPath: derivedDataPath))
        if !signing.isEmpty {
            try? (signing + "\n").write(to: signingFingerprintPath, atomically: true, encoding: .utf8)
        }
    }

    /// 署名設定の指紋(codeSigningArguments を結合。シミュレータは空)。.toolchain と同じく
    /// DerivedData ルートに置き、成果物と一緒に消える
    var signingFingerprintPath: URL { derivedDataPath.appendingPathComponent(".signing") }

    func currentSigningFingerprint() -> String {
        ((try? codeSigningArguments()) ?? []).joined(separator: "\n")
    }

    /// current が空(シミュレータ = 署名なし)は常に一致扱い —— 空同士を不一致にすると
    /// 署名の無いビルドを毎回捨てることになる。指紋ファイル不在(この仕組み以前の成果物)は
    /// 不一致 = 一度だけ建て直す(古いまま走らせるより安全。ToolchainFingerprint と同じ向き)
    static func signingMismatch(stored: String?, current: String) -> Bool {
        guard !current.isEmpty else { return false }
        return stored?.trimmingCharacters(in: .whitespacesAndNewlines) != current
    }

    /// 既存の xctestrun があってもソース/ツールチェーン/署名設定が変わっていれば建て直す。
    /// 「xctestrunNotFound のときだけ build」の起動ヘルパー(XCUIBridgeResolver /
    /// LiveBridgeAutoStarter)が旧成果物を起動し続けないための前段
    /// (BridgeProvisioner.prepareSharedBuilds と同じ判定)。xctestrun 不在は何もしない
    /// = 従来の xctestrunNotFound → buildForTesting 経路に任せる
    public func rebuildIfStale() throws {
        guard let xctestrun = try findXCTestRun() else { return }
        if Self.runnerNeedsRebuild(repoRoot: repoRoot, xctestrun: xctestrun,
                                   signing: currentSigningFingerprint()) {
            try buildForTesting()
        }
    }

    /// 失敗したビルドの生出力を残す(畳んだ案内から辿れるように)。**書けなくても失敗させない**
    /// —— ここで throw すると、本題(署名の案内)が届かなくなる
    private func writeBuildLog(_ output: String) -> URL? {
        let url = stateDir.appendingPathComponent("bridge-build-\(port).log")
        return (try? output.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }

    /// ランナーをどの Xcode/SDK で作ったかの記録(DerivedData 配下 = 成果物と一緒に消える場所)
    static func runnerFingerprintPath(derivedDataPath: URL) -> URL {
        derivedDataPath.appendingPathComponent(".toolchain")
    }

    /// 保存済みの指紋が現在のツールチェーンと食い違っていればその指紋を返す(doctor の警告用)。
    /// 未ビルド(指紋なし)は nil = 何も言わない —— 作り直しの必要ではなく未導入なので、
    /// ここで警告すると初回の受け手に「壊れている」と読める。
    ///
    /// **成果物の Info.plist を見てはいけない**(2026-08-25 に誤検知): `XCTRunner.app` は
    /// ビルドの生成物ではなく **プラットフォーム SDK のテンプレートのコピー**で、その
    /// `DTXcodeBuild` はテンプレート自身の値(Xcode 27 beta 6 では `27A252`)のまま残る。
    /// `xcodebuild -version` の `27A5252f` とは体系が違うので、建て直しても永久に警告し続ける。
    /// 判定は再ビルドの砦(`runnerNeedsRebuild`)と同じ指紋に一本化する。
    public static func staleRunnerToolchain(
        repoRoot: URL, physical: Bool = false,
        current: String? = ToolchainFingerprint.current()
    ) -> String? {
        let derivedData = BridgeLauncher(repoRoot: repoRoot, physical: physical).derivedDataPath
        let path = runnerFingerprintPath(derivedDataPath: derivedData)
        guard let stored = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current, trimmed != current else { return nil }
        return trimmed
    }

    /// xctestrun から上方向に .toolchain を探す(<DerivedData>/Build/Products/ の 3 階層想定 + 余裕)
    static func findRunnerFingerprint(near xctestrun: URL) -> URL? {
        var dir = xctestrun.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent(".toolchain")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// 実機ビルドは署名が要る。team は ~/.config/fleetest/config.json の developmentTeam か
    /// FT_DEVELOPMENT_TEAM。-allowProvisioningUpdates で App ID/プロファイルの自動登録を許す。
    /// シミュレータでは空(署名不要のまま従来どおり)
    func codeSigningArguments() throws -> [String] {
        guard physical else { return [] }
        let signing = LocalConfig.codeSigning()
        // team 無しで走らせると xcodebuild が「No profiles for '...' were found」等の
        // 原因の分かりにくい署名エラーで落ちる。設定不足はここで明示的に止める
        guard let team = signing.team else { throw LauncherError.developmentTeamMissing }
        // FT_BUNDLE_ID_PREFIX は project.yml が $(FT_BUNDLE_ID_PREFIX) で参照するユーザー定義設定。
        // ここでコマンドライン上書きすると3ターゲットの bundle id がまとめてチーム固有になる
        return ["-allowProvisioningUpdates",
                "CODE_SIGN_STYLE=Automatic",
                "FT_BUNDLE_ID_PREFIX=\(signing.bundleIDPrefix)",
                "DEVELOPMENT_TEAM=\(team)"]
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
            // 無通信 TTL。ホストで解決してから数値文字列で渡す(ランナー側は再解釈するだけ)
            env["FT_BRIDGE_TTL"] = String(BridgeAPI.resolvedBridgeTTLSeconds(
                ProcessInfo.processInfo.environment["FT_BRIDGE_TTL"]))
            // 起動元の自己申告(/status の ownerRepo。doctor の刈り取り判定が依存)
            env["FT_OWNER_REPO"] = repoRoot.path
            // 実機はデバイス内ループバックがホストから見えないので全インターフェースに開く。
            // 同期相手: Runner/FleetestRunnerUITests/BridgeHTTPServer.swift の start()
            if physical { env["FT_BIND_ALL"] = "1" }
            // ブリッジ内の所要内訳ログ(既定 off)。ホスト側の FT_HTTP_TIMING と対で使い、
            // 「ホストの actionMs とブリッジのハンドラ計時の差」を突き合わせるためだけのもの
            if ProcessInfo.processInfo.environment["FT_BRIDGE_TIMING"] == "1" {
                env["FT_BRIDGE_TIMING"] = "1"
            }
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
            .appendingPathComponent("FleetestRunner-\(port).xctestrun")
        let outData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try outData.write(to: output)
        return output
    }

    /// HTTP サーバだけ死んで親 xcodebuild が残留するケースの後始末。起動前に走らせないと
    /// pid ファイルが新プロセスの PID で上書きされ、旧プロセスがどの pid ファイルからも
    /// 参照されない残骸になる。マッチはこのポート専用の xctestrun ファイル名
    /// (FleetestRunner-<port>.xctestrun。ポートごとに別ファイルなので他ポートは誤爆しない)を
    /// コマンドラインに含む xcodebuild のみ対象にする。
    func killOrphanRunners() {
        let xctestrunPath = derivedDataPath
            .appendingPathComponent("Build/Products/FleetestRunner-\(port).xctestrun").path
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
            remaining = remaining.filter { ProcessLiveness.isAlive($0) }
            if remaining.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        for pid in remaining { kill(pid, SIGKILL) }
        let message = "→ Cleaned up leftover runner(s) on port \(port) (pid \(pids.map(String.init).joined(separator: ", ")))\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    public func stop() throws {
        // 実機の到達手段(iproxy トンネル・endpoint 記録)はブリッジと寿命を揃える。
        // 残すと次回 provision が死んだブリッジ宛の古い宛先を再利用する。
        // **physical で条件分岐しない**: `bridge down --port N` のように kind を知らない経路からも
        // 停止されるため。シミュレータのポートには記録もトンネルも無いので teardown は no-op
        IOSDeviceTransport.teardown(port: port, repoRoot: repoRoot)
        guard let pidString = try? String(contentsOf: pidPath, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            // pid ファイルが無くても in-app ブリッジ(dylib 注入・pid ファイル非対応)の
            // 状態ファイルがあれば simctl terminate で後始末する
            let inappPath = InAppBridgeState.url(stateDir: stateDir, port: port)
            guard FileManager.default.fileExists(atPath: inappPath.path) else {
                // 状態ファイルが無くても**ポートで応答していれば**別クローン/別ワークスペースの
                // ブリッジ。「起動していません」は事実と食い違うので言い分ける
                if let status = Self.probeForeignBridge(port: port) {
                    throw LauncherError.notOwnedByThisRepo(
                        port: port, device: status.device, protocolVersion: status.protocolVersion)
                }
                throw LauncherError.notRunning(port: port)
            }
            InAppBridgeState.terminateAndRemove(at: inappPath)
            return
        }
        kill(pid, SIGTERM)
        // 死亡確認してから pid ファイルを消す。即削除すると assignPort がそのポートを空きと誤認し、
        // まだ生きているプロセスとの同ポート再起動で bindFailed(48) を招く(stopAndWait と同じ理由)。
        Self.confirmDeathThenRemovePidFile(pid: pid, pidPath: pidPath, timeout: 5)
    }

    /// ポートで応答しているブリッジの /status を同期で1回だけ引く(このリポジトリの管理外か判定用)。
    /// stop() が同期メソッドなので URLSession の async は使わず、セマフォで待つ。
    /// 到達しなければ nil(= 本当に起動していない)。
    public static func probeForeignBridge(port: UInt16, timeout: TimeInterval = 1.5)
        -> StatusResponse? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/status") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var result: StatusResponse?
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        URLSession(configuration: config).dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data else { return }
            result = try? JSONDecoder().decode(StatusResponse.self, from: data)
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.5)
        return result
    }

    /// doctor の刈り取り用: pid が FleetestRunner のランナーであることを ps で確認してから
    /// SIGTERM する(PID 再利用で無関係なプロセスを撃たないため)。戻り値 = 停止したか
    public static func reapRunnerProcess(pid: Int32) -> Bool {
        let ps = try? Shell.run(["ps", "-ww", "-p", String(pid), "-o", "command="])
        guard let ps, ps.status == 0, ps.output.contains("FleetestRunner") else { return false }
        kill(pid, SIGTERM)
        confirmDeaths(pids: [pid], timeout: 5)
        return true
    }

    /// SIGTERM 済みの pid の消滅を timeout まで待ち、生き残れば SIGKILL してから pid ファイルを削除する。
    /// 同期版(stop が使う。async は stopAndWait 参照)。
    static func confirmDeathThenRemovePidFile(pid: Int32, pidPath: URL, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessLiveness.isAlive(pid) {
                try? FileManager.default.removeItem(at: pidPath)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(pid, SIGKILL)
        Thread.sleep(forTimeInterval: 0.5)
        try? FileManager.default.removeItem(at: pidPath)
    }

    /// SIGTERM 済みの pid 群の消滅を timeout まで待ち、生き残りを SIGKILL する(stopAll/stopMatching 用)。
    /// 呼び出し元は直後に simctl shutdown を実行するため、ここで待たずに返すと生きた XCUITest
    /// セッションの teardown と shutdown が競合し、セッションがシャットダウン中のシミュレータを
    /// 再ブートさせる。再ブートで起き上がった SpringBoard は表示サービス不在の assert
    /// (FBSDisplayMonitor)でクラッシュループし、macOS のクラッシュダイアログが連発する(実害あり)。
    static func confirmDeaths(pids: [Int32], timeout: TimeInterval) {
        var remaining = Set(pids.filter { ProcessLiveness.isAlive($0) })
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !remaining.isEmpty {
            Thread.sleep(forTimeInterval: 0.2)
            remaining = remaining.filter { ProcessLiveness.isAlive($0) }
        }
        guard !remaining.isEmpty else { return }
        for pid in remaining { kill(pid, SIGKILL) }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// 同一ポートで起動し直す前に旧プロセスの消滅を待つ(stop() は待たないため、直後の
    /// startDetached が旧ブリッジの /status を拾って偽の起動成功になる)
    public func stopAndWait(timeout: TimeInterval = 10) async throws {
        guard let pidString = try? String(contentsOf: pidPath, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LauncherError.notRunning(port: port)
        }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessLiveness.isAlive(pid) {
                try? FileManager.default.removeItem(at: pidPath)
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        kill(pid, SIGKILL)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try? FileManager.default.removeItem(at: pidPath)
    }

    /// pid ファイルが指すプロセスの経過時間(秒)。pid ファイルが無い/プロセスが既に居ない/
    /// ps が読めないときは nil(unknown。呼び手は「待つ」側に倒す)。単一 pid の照会なので
    /// portsMatching の「ps は1回だけ」規律(複数 pid をまとめて引く)は適用されない
    public func runnerElapsed() -> TimeInterval? {
        guard let pidString = try? String(contentsOf: pidPath, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let ps = try? Shell.run(["ps", "-p", String(pid), "-o", "etime="]),
              ps.status == 0 else { return nil }
        return PSElapsedTime.parse(ps.output)
    }

    /// 指定 UDID を対象にするブリッジのポート一覧(停止しない読み取り専用)。
    /// **実機のブリッジ帰属判定はこれで行う**: /status の device 名は実機だと機種名("iPhone")で
    /// マシンプロファイルのデバイス名と一致しないため、名前照合では永久に紐付かない。
    /// 特定は stopMatching と同じくプロセスの起動引数(-destination ... id=<UDID>)照合。
    /// stale な pid ファイルはここでは消さない(読み取り専用に徹する。掃除は stopMatching の役割)
    public static func portsMatching(udid: String, repoRoot: URL) -> [UInt16] {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return [] }
        var portByPID: [Int32: UInt16] = [:]
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "pid" {
            guard let pidString = try? String(contentsOf: entry, encoding: .utf8),
                  let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let port = UInt16(entry.deletingPathExtension().lastPathComponent
                      .replacingOccurrences(of: "bridge-", with: "")) else { continue }
            portByPID[pid] = port
        }
        guard !portByPID.isEmpty else { return [] }
        // **ps は 1 回だけ**(pid ごとに spawn すると、monitor が 2 秒間隔でこれを呼ぶので
        // 常駐ブリッジ本数 × 0.5 回/秒のプロセス生成になる)。
        // **`ps -p <pid列>` を使ってはいけない**: 範囲外の pid が 1 つ混じるとエラーになり
        // **生きている分も含めて出力が空になる**(pid ファイルは壊れた値を持ち得る)。
        // 全プロセス列挙して pid で引く方がゴミ値に強い
        guard let ps = try? Shell.run(["ps", "-ax", "-o", "pid=,command="]) else { return [] }
        var ports: [UInt16] = []
        for line in ps.output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), trimmed.contains(udid),
                  let pid = Int32(trimmed[..<space]), let port = portByPID[pid] else { continue }
            ports.append(port)
        }
        return ports.sorted()
    }

    /// portsMatching を複数 UDID 分まとめて引く(`ps` は 1 回だけ)。
    /// **/status に未応答=announce 前のランナーもここには映る**のが要点。provision の
    /// 「同一デバイスに 2 本目の XCUITest ランナーを立てない」判定はこれを使う
    /// (announce 済みブリッジしか見ない scanRunningBridges では、別プロセスが起動した直後の
    /// ランナーが見えず、空きポートに 2 本目を立てて OS の 1 デバイス 1 ランナー制約で全滅する)。
    public static func portsByUDID(_ udids: [String], repoRoot: URL) -> [String: [UInt16]] {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        guard !udids.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: stateDir, includingPropertiesForKeys: nil) else { return [:] }
        var portByPID: [Int32: UInt16] = [:]
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "pid" {
            guard let pidString = try? String(contentsOf: entry, encoding: .utf8),
                  let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let port = UInt16(entry.deletingPathExtension().lastPathComponent
                      .replacingOccurrences(of: "bridge-", with: "")) else { continue }
            portByPID[pid] = port
        }
        guard !portByPID.isEmpty else { return [:] }
        // portsMatching と同じ理由で `ps` は全列挙 1 回(`ps -p <pid列>` はゴミ pid 1 つで全滅する)
        guard let ps = try? Shell.run(["ps", "-ax", "-o", "pid=,command="]) else { return [:] }
        var result: [String: [UInt16]] = [:]
        for line in ps.output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<space]), let port = portByPID[pid] else { continue }
            for udid in udids where trimmed.contains(udid) {
                result[udid, default: []].append(port)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    /// 指定シミュレータ(UDID)を対象にするブリッジプロセスを pid ファイルから探して全て停止する。
    /// 特定はプロセスの起動引数(-destination ... id=<UDID>)照合。/status 無応答のゾンビ
    /// xcodebuild は HTTP スキャンに映らないがこれなら殺せる(生きた XCUITest セッションを残すと
    /// シミュレータが再ブートされ「停止したのに起動中に戻る」症状になる)。戻り値=停止ポート一覧
    public static func stopMatching(udid: String, repoRoot: URL) -> [String] {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return [] }
        var stopped: [String] = []
        var terminated: [Int32] = []
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
            terminated.append(pid)
            try? FileManager.default.removeItem(at: entry)
            stopped.append(entry.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "bridge-", with: ""))
        }
        // 直後の simctl shutdown と XCUITest teardown の競合防止(confirmDeaths のコメント参照)
        confirmDeaths(pids: terminated, timeout: 5)
        // in-app ブリッジ(pid ファイルを持たない。/status 無応答のウェッジも含めて udid 一致だけで判定)
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "inapp" {
            guard let state = InAppBridgeState.read(at: entry), state.udid == udid else { continue }
            InAppBridgeState.terminateAndRemove(at: entry)
            stopped.append(entry.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "bridge-", with: ""))
        }
        return stopped.sorted()
    }

    /// 死んだランナーの pid ファイルを掃除する(停止はしない)。TTL 自主終了(design.md §4.1)は
    /// ホスト側の pid ファイルを消せないため、放置すると assignPort がそのポートを使用中と
    /// みなし採番がドリフトする。provision のプランニング前(ProvisionLock 内)から呼ぶ
    public static func sweepStalePidFiles(repoRoot: URL) {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "pid" {
            let port = entry.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "bridge-", with: "")
            // stopAll と同じ同定(PID 再利用対策): 当該ポートのランナーが生きているときだけ残す
            if let pidString = try? String(contentsOf: entry, encoding: .utf8),
               let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let ps = try? Shell.run(["ps", "-ww", "-p", String(pid), "-o", "command="])
                if let ps, ps.status == 0, ps.output.contains("FleetestRunner-\(port).xctestrun") {
                    continue
                }
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// ps のコマンドラインから「実機向けランナーか」を判定する。実機とシミュレータは DerivedData を
    /// 分けてあり(derivedDataPath)、-xctestrun のパスがそこを通るのでこれで一意に分かれる
    static func isPhysicalRunnerCommand(_ command: String) -> Bool {
        command.contains("DerivedData-device")
    }

    /// .fleetest/bridge-*.pid(xcuitest)と bridge-*.inapp(dylib 注入)を走査して全ブリッジを
    /// 停止する。戻り値は停止したポート一覧。
    /// - skipPhysical: true なら実機向けランナー(isPhysicalRunnerCommand で同定)を対象から外す
    ///   (ユーザー決定: 一括デバイス操作は実機を触らない。`bridge down --all` は false で呼ぶ)。
    ///   **既定値は置かない** —— 新しい呼び出し元が選択を明示せず素通りするのを防ぐ。
    ///   除外した実機は kill もせず pid ファイルも消さない(生きているランナーのファイルを
    ///   消すとポート採番(assignPort)が壊れる)
    public static func stopAll(repoRoot: URL, skipPhysical: Bool) -> [String] {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return [] }
        var stopped: [String] = []
        var terminated: [Int32] = []
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-") {
            switch entry.pathExtension {
            case "pid":
                guard let pidString = try? String(contentsOf: entry, encoding: .utf8),
                      let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    try? FileManager.default.removeItem(at: entry)
                    continue
                }
                let port = entry.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "bridge-", with: "")
                // PID 再利用対策: pid ファイルの PID が実際に当該ポートのランナーか cmdline で確認してから
                // 殺す(stopMatching/killOrphanRunners と同方針)。-ww で cmdline 切り詰めを防ぎ、
                // -xctestrun のポート専用ファイル名で同定する。無関係な再利用 PID は撃たない。
                let ps = try? Shell.run(["ps", "-ww", "-p", String(pid), "-o", "command="])
                guard let ps, ps.status == 0, ps.output.contains("FleetestRunner-\(port).xctestrun") else {
                    // 同定できない stale な pid ファイルは掃除する(assignPort の採番ずれ防止)。
                    try? FileManager.default.removeItem(at: entry)
                    continue
                }
                if skipPhysical, isPhysicalRunnerCommand(ps.output) {
                    continue
                }
                kill(pid, SIGTERM)
                terminated.append(pid)
                stopped.append(port)
                try? FileManager.default.removeItem(at: entry)
            case "inapp":
                // in-app ブリッジ(dylib 注入)はシミュレータ専用(実機に in-app 注入は無い)ので
                // skipPhysical に関わらず全部止めてよい
                InAppBridgeState.terminateAndRemove(at: entry)
                stopped.append(entry.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "bridge-", with: ""))
            default:
                continue
            }
        }
        // 直後の simctl shutdown all と XCUITest teardown の競合防止(confirmDeaths のコメント参照)
        confirmDeaths(pids: terminated, timeout: 5)
        return stopped
    }

    /// host: 実機は LAN IP か iproxy のループバック(IOSDeviceTransport が確立済みのもの)を渡す。
    /// log: 実機で「失敗ではないが進まない」条件(端末ロック等)を1回だけ知らせるための出力先
    /// **xcodebuild のテストセッションが既に終わっている**ことをログから判定する。
    /// 終わっていれば ready には二度とならないので、待ち続けても既定 180 秒を捨てるだけ
    /// (2026-08-05 実測: 未インストールのアプリを launch してランナーが落ちた後、次の
    /// provision がこの待ちで 3 分級になった)。**pid の生死では判定できない** ——
    /// テストが失敗しても xcodebuild は後始末の間だけ生きており、`ps` にも残る。
    /// ログは起動のたびに空で作り直される(startDetached の createFile)ので、
    /// 見つかったマーカーは必ず今回のもの
    public static func runnerSessionEnded(inLog text: String) -> String? {
        for marker in ["** TEST EXECUTE FAILED **", "** BUILD INTERRUPTED **", "Testing failed:"]
        where text.contains(marker) {
            return marker
        }
        return nil
    }

    /// ブリッジ起動の締切(秒)。実機の解除待ち(IOSPhysicalDeviceLock)もこの予算を使う
    /// —— あちらは「起動を始めてよい状態になるまで」で、待った分だけ deviceprep の
    /// 無情報な待ちが減る(猶予の上乗せではない)
    public static let startupTimeoutSeconds: TimeInterval = 180

    public func waitUntilReady(timeout: TimeInterval = BridgeLauncher.startupTimeoutSeconds,
                               host: String = BridgeEndpoint.loopbackHost,
                               log: @escaping (String) -> Void = { _ in }) async throws {
        let client = BridgeClient(port: port, host: host)
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        var blocker: String?
        /// 実機の診断。LAN は宛先解決(waitForAnnouncedAddress)側でも同じ判定をするが、
        /// **USB はそこを通らない**ため、ここで見ないと端末ロック・証明書未信頼が原因不明の
        /// タイムアウトになる(実害)。判定の知識は IOSDeviceTransport の 2 関数に集約。
        /// 致命的(証明書未信頼など)は throw、待てば解ける条件(ロック)は文言を返す
        func physicalDiagnosis() throws -> String? {
            guard physical, let text = try? String(contentsOf: logPath, encoding: .utf8) else {
                return nil
            }
            if let reason = IOSDeviceTransport.runnerFailureReason(inLog: text) {
                throw IOSDeviceTransportError.runnerFailed(
                    port: port, reason: reason, logPath: logPath.path)
            }
            return IOSDeviceTransport.blockingCondition(inLog: text)
        }
        while Date() < deadline {
            // キャンセルで抜ける(IOSDeviceTransport.waitForAnnouncedAddress と同じ理由)
            try Task.checkCancellation()
            do {
                let status = try await client.status()
                if status.ready {
                    enableReduceMotion()
                    return
                }
            } catch {
                lastError = error
            }
            // **終わったセッションを待たない**(理由は runnerSessionEnded)
            if let text = try? String(contentsOf: logPath, encoding: .utf8),
               let marker = Self.runnerSessionEnded(inLog: text) {
                throw LauncherError.timedOut("the test session already ended (\(marker))",
                                             logPath.path)
            }
            // startDetached が logPath を毎回空で作り直す(createFile)ため、ここで見つかる
            // bindFailed は必ず今回の起動試行のもの。180 秒待たずに fail-fast する
            // (別プロセスがポートを握っている限り再試行しても直らないため)。
            if logTailContainsBindFailed() {
                throw LauncherError.portInUse(port: port, holder: nil)
            }
            if let detected = try physicalDiagnosis(), detected != blocker {
                blocker = detected
                log("⏳ \(detected)")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // **締切後にもう一度読む**: xcodebuild は諦めた時点で初めて理由をログに書くことがある
        // (ロック中の deviceprep エラーは実測でそう。2026-07-25)。ループ内の読み取りだけでは
        // 「network connection was lost で 180 秒後にタイムアウト」という無情報な失敗になる
        blocker = try physicalDiagnosis() ?? blocker
        if let blocker {
            throw IOSDeviceTransportError.addressNotAnnounced(
                port: port, logPath: logPath.path, blocker: blocker)
        }
        throw LauncherError.timedOut(lastError.map { "\($0)" } ?? "no response", logPath.path)
    }

    /// 検知文字列 "bindFailed(" は Runner/FleetestRunnerUITests/BridgeHTTPServer.swift の
    /// ServerError.bindFailed(errno)(XCTest 失敗ログに Swift 既定の記述で出力される)との言語間契約。
    /// 変更する場合は両方を同期させること。
    private func logTailContainsBindFailed() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: logPath) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        let readSize: UInt64 = 64 * 1024
        let offset = size > readSize ? size - readSize : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return false }
        return String(data: data, encoding: .utf8)?.contains("bindFailed(") ?? false
    }

    /// コールド起動時のみ実行(稼働中ブリッジの再利用時はここを通らない。run 開始ごとの同期は
    /// ProfileWorkerFactory.syncAnimationSettings)。設定は以後起動されるアプリに効く
    /// (実行中アプリには効かない。/session がシナリオ毎に再起動するので問題ない)。失敗は非致命。
    private func enableReduceMotion() {
        // simctl spawn は実機に無い。実機のアクセシビリティ設定はホストから変えられないので
        // 何もしない(端末側で「視差効果を減らす」を手動 ON にすると整定が速くなる)
        if physical { return }
        IOSReduceMotion.apply(
            udid: device,
            animationsEnabled: AnimationPolicy.animationsEnabled()) { message in
                FileHandle.standardError.write(Data("\(message)\n".utf8))
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
                && $0.lastPathComponent.contains("FleetestRunner")
                // 自分が生成したポート注入コピー(FleetestRunner-<port>.xctestrun)は除外
                && !($0.lastPathComponent.hasPrefix("FleetestRunner-"))
        }
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// ランナーのソースが xctestrun より新しいか(InAppLauncher.needsBuild と対の鮮度判定)。
    /// これが無いと prepareSharedBuilds は「xctestrun 不在」しか見ず、ソース変更後も旧バイナリを
    /// 起動し続ける(旧版検知 → 停止 → 同じ旧バイナリで再起動、の毎 run ループになる。2026-07-28 実害)
    static func runnerNeedsRebuild(repoRoot: URL, xctestrun: URL, signing: String,
                                   toolchain: String? = ToolchainFingerprint.current()) -> Bool {
        guard let built = (try? xctestrun.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
              let newest = newestRunnerSourceTimestamp(repoRoot: repoRoot) else { return true }
        if newest > built { return true }
        // Xcode/SDK を上げてもソースの mtime は動かない。指紋が変わっていたら作り直す
        // (旧 Xcode のランナーを新ランタイムに載せると実行中に「Application is not running」で落ちる)
        // 指紋は DerivedData ルートに置く。xctestrun からの相対位置は Xcode の出力レイアウトに
        // 依存するので、決め打ちせず上方向に探す(見つからなければ「旧版の成果物」= 作り直す)
        guard let fingerprint = findRunnerFingerprint(near: xctestrun) else { return true }
        if !ToolchainFingerprint.matches(storedAt: fingerprint, current: toolchain) { return true }
        // 署名設定(チーム・接頭辞)の変更もソースの mtime を動かさない(buildForTesting の doc)
        let storedSigning = try? String(
            contentsOf: fingerprint.deletingLastPathComponent().appendingPathComponent(".signing"),
            encoding: .utf8)
        return signingMismatch(stored: storedSigning, current: signing)
    }

    /// ランナーのビルド入力の最終更新時刻。入力集合は Runner/project.yml の sources と対
    /// (FleetestRunnerUITests/ + FleetestRunnerApp/ + project.yml + 共有 DTO の BridgeDTO.swift)。
    /// 取得できない場合は nil = 「判定不能」として再ビルドさせる(古いまま走らせるより安全)
    static func newestRunnerSourceTimestamp(repoRoot: URL) -> Date? {
        var inputs = [
            repoRoot.appendingPathComponent("Runner/project.yml"),
            repoRoot.appendingPathComponent("Sources/FTCore/BridgeDTO.swift"),
        ]
        for dir in ["Runner/FleetestRunnerUITests", "Runner/FleetestRunnerApp"] {
            let dirURL = repoRoot.appendingPathComponent(dir)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                return nil
            }
            inputs.append(contentsOf: entries.filter { !$0.hasDirectoryPath })
        }
        var newest = Date.distantPast
        for url in inputs {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { return nil }
            newest = max(newest, date)
        }
        return newest
    }
}

public enum LauncherError: Error, LocalizedError {
    case commandFailed(String, String)
    case xctestrunNotFound(String)
    /// port: どの pid ファイルを探して無かったか。**素の "bridge.pid" と言わない** ——
    /// 実在するのは常に `bridge-<port>.pid` で、その名前で grep しても何も出ない(2026-09-04)
    case notRunning(port: UInt16?)
    /// ポートでブリッジが応答しているのに、このリポジトリの状態ファイル(.fleetest/)に記録が無い。
    /// 別クローン・別ワークスペースが起動したブリッジを掴んでいる状態。
    case notOwnedByThisRepo(port: UInt16, device: String?, protocolVersion: Int?)
    case timedOut(String, String)
    /// bindFailed(48) 検知(waitUntilReady のログ監視)。holder は判明していれば占有プロセスの説明
    case portInUse(port: UInt16, holder: String?)
    /// 実機ビルドに必要な Team ID が未設定(署名エラーになる前に止める)
    case developmentTeamMissing
    /// 署名設定が足りずランナーを実機向けに建てられない。**文字列ではなく「何が欠けているか」を
    /// 運ぶ** —— CLI は英語で案内を出し、拡張は同じ判定から**自分の言語で**案内を組み立てる
    /// (CLAUDE.md「共有するのは判定であって文言ではない」)。生のビルドログはファイルへ
    case codeSigningIncomplete(problems: [XcodeSigningProblem], logPath: String?)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd, let tail):
            return "\(cmd) failed:\n\(tail)"
        case .xctestrunNotFound(let path):
            return "xctestrun not found (build-for-testing must run first): \(path)"
        case .notRunning(let port):
            let file = port.map { ".fleetest/bridge-\($0).pid" } ?? ".fleetest/bridge-<port>.pid"
            return "the bridge is not running (no \(file))"
        case .notOwnedByThisRepo(let port, let device, let version):
            // 「起動していません」と言うと事実と食い違う(実際は応答している)。実害: 別クローンの
            // 旧版ブリッジがポートとシミュレータを 7 時間握り、原因の切り分けに時間を要した
            let target = device.map { "device \($0)" } ?? "unknown device"
            let ver = version.map { "protocolVersion \($0)" } ?? "unknown version"
            return "the bridge on port \(port) is not managed by this repository"
                + " (\(target) / \(ver)). It does respond, so there is something to stop — "
                + "**a bridge started by another clone or workspace**. "
                + "Stop it from there, or kill the process from `lsof -ti :\(port)`"
                + " (on iOS, after stopping xcodebuild also run `xcrun simctl terminate <udid> "
                + "com.example.ftrunner.uitests.xctrunner`)"
        case .timedOut(let lastError, let log):
            return "bridge start-up timed out (last error: \(lastError)). Log: \(log)"
        case .portInUse(let port, let holder):
            if let holder {
                return "port \(port) is in use by another process (\(holder))"
            }
            return "port \(port) is in use by another process"
        case .codeSigningIncomplete(let problems, let logPath):
            return XcodeSigningDiagnosis.guidance(
                problems: problems, fullLogPath: logPath,
                overSSH: XcodeSigningDiagnosis.isSSHSession(environment: ProcessInfo.processInfo.environment))
                ?? "the runner cannot be code-signed for a physical device"
        case .developmentTeamMissing:
            return "building for a physical iOS device requires an Apple Developer Team ID. "
                + "Set \"developmentTeam\" in ~/.config/fleetest/config.json or the "
                + "FT_DEVELOPMENT_TEAM environment variable"
                + " (the Team ID is the OU of the signing certificate — check with `security find-certificate -c "
                + "\"Apple Development: <you>\" -p | openssl x509 -noout -subject`; "
                + "the value in parentheses from `security find-identity` is a certificate ID, not a Team ID)"
        }
    }
}

/// Bundle(for:) にモジュールの所在を教えるためだけの型(削除するとバンドル解決が main へ落ちる)
private final class BundleToken {}

public enum RepoRoot {
    /// ブリッジ資産(Runner/・InAppBridge/・Sources/FTCore/BridgeDTO.swift など)を持つルートを返す。
    /// = ツール本体(foundation-tester)のソースルート。シナリオがビルドされる受け手のパッケージ
    /// (ScenarioHost.packageRoot())とは別物で、外部パッケージ構成では両者が食い違う。
    public static func find() throws -> URL {
        // 0. 明示指定(FT_TOOL_ROOT)。cwd も実行ファイルの位置も当てにできない起動経路
        //    (MCP クライアントが任意の cwd でサーバを起こす等)のための逃げ道。
        //    設定されているのに Runner/ が無ければ探索へフォールバックせず失敗する
        //    (誤設定を黙って別ルートで動かすと診断不能になる。FT_PACKAGE_ROOT と同じ規律)
        if let override = ProcessInfo.processInfo.environment["FT_TOOL_ROOT"], !override.isEmpty {
            let dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            guard hasRunner(dir) else {
                throw LauncherError.commandFailed(
                    "repo root detection",
                    "FT_TOOL_ROOT=\(override) has no bridge assets (Runner/project.yml). "
                        + "Point it at the root of the foundation-tester clone")
            }
            return dir
        }
        // 1. clone 構成: 実行ディレクトリの上方に Package.swift + Runner/ があればそれ(ツール repo 内実行)。
        //    外部パッケージ構成: 受け手パッケージ(Runner/ 無し)なら、その SPM checkout に foundation-tester が
        //    展開されているのでそれを使う(.build/checkouts/*/Runner/。fleetest CLI がどこでビルドされたかに
        //    依らず解決可 = ビルド元のソースツリーが既に無い場合でも #filePath に頼らず済む)。
        //    ※ path 依存(.package(path:))では checkouts が作られないので 2 で解決する。
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                if hasRunner(dir) { return dir }
                if let checkout = checkoutWithRunner(userPackage: dir) { return checkout }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // 2. 実行中バイナリの位置から(<TOOL_ROOT>/.build/debug/fleetest-mcp 等)。cwd が受け手パッケージに
        //    固定される MCP サーバはここで解決される。symlink 解決が必須
        //    (.build/debug は out/Products/Debug への symlink)。
        if let executableRoot = executableRoot() { return executableRoot }
        // 3. 最後のフォールバック: #filePath(コンパイル時に焼かれる自ソースの絶対パス)からツールソース
        //    へ。SPM local path 依存(--fleetest-path)や自前ビルドではソースがそのパスに実在する。
        //    ※ ビルド元のソースが既に削除・移動されていれば #filePath は死んでいる(上の 1/2 で解決)。
        if let toolRoot = toolSourceRoot() { return toolRoot }
        throw LauncherError.commandFailed(
            "repo root detection",
            "bridge assets (Runner/) not found. The foundation-tester sources are required"
                + " (in the external-package layout, the consumer package .build/checkouts or the --fleetest-path sources are used). "
                + "The clone root can also be set explicitly via the FT_TOOL_ROOT environment variable")
    }

    private static func hasRunner(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("Runner/project.yml").path)
    }

    /// 受け手パッケージの SPM checkout(.build/checkouts/<name>/)から Runner/ を持つものを探す。
    static func checkoutWithRunner(userPackage: URL) -> URL? {
        let checkouts = userPackage.appendingPathComponent(".build/checkouts")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: checkouts, includingPropertiesForKeys: nil) else { return nil }
        return entries.first(where: hasRunner)
    }

    /// 実行中バイナリの実体パス(symlink 解決済み)から上方に辿り、Runner/ を持つルートを探す。
    /// 先頭は**このモジュールを含むバンドル**(通常は実行ファイル本体、テストでは .xctest)。
    /// Bundle.main はホストが別実行ファイル(xctest 等)のとき別の場所を指すため単独では足りない。
    static func executableRoot() -> URL? {
        let candidates = [
            Bundle(for: BundleToken.self).executableURL,
            Bundle.main.executableURL,
            CommandLine.arguments.first.map { URL(fileURLWithPath: $0) },
        ].compactMap { $0 }
        for candidate in candidates {
            var dir = candidate.resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<10 {
                if hasRunner(dir) { return dir }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    /// #filePath(このソースの絶対パス)から上方に辿り、Runner/ を持つツールソースルートを探す。
    static func toolSourceRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if hasRunner(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
