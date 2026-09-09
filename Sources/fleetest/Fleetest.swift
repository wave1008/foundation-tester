import ArgumentParser
import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import FTDSL

@main
struct Fleetest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fleetest",
        abstract: "iOS/Android app testing tool for macOS",
        version: ToolVersion.describe(),
        subcommands: [
            InitCommand.self,
            Doctor.self,
            Bridge.self,
            Install.self,
            Launch.self,
            Snapshot.self,
            Tap.self,
            TypeCommand.self,
            Swipe.self,
            Press.self,
            Screenshot.self,
            Terminate.self,
            RunScenarios.self,
            RunFileCommand.self,
            DraftScenarioCommand.self,
            ProjectCommand.self,
            ProfileCommand.self,
            DevicesCommand.self,
            ApiCommand.self,
            ResultsCommand.self,
            RemoteCommand.self,
            HooksCommand.self,
            MonitorCommand.self,
        ]
    )

    /// AsyncParsableCommand の既定 main() を隠し、パース前に武装だけ差し込む
    /// (`FT_PARENT_PID` が無ければ armIfRequested は no-op = 挙動は変わらない)。
    /// `self.main(nil)` は AsyncParsableCommand 拡張の `main(_ arguments:)` を呼ぶ ——
    /// asyncParseAsRoot → run() → catch { exit(withError:) } の既定挙動をそのまま保つ
    static func main() async {
        ParentDeathWatch.armIfRequested()
        LedgerWriteRole.enableForProduction()
        await self.main(nil)
    }
}

struct DriverOptions: ParsableArguments {
    @Option(help: "Target platform: ios / android (default ios)")
    var platform: String?

    @Option(name: .long, help: "Bridge port number (iOS only; default \(BridgeAPI.defaultPort))")
    var port: UInt16?

    @Option(help: "Android device serial (adb -s; defaults to the only connected device)")
    var serial: String?

    @Flag(help: "Proceed even if the connected bridge's protocol version differs from this build (manual drive commands only)")
    var allowVersionSkew = false

    /// `makeDriver` を通らないコマンド(`bridge up/status`・`api list-apps`・`api live`)が
    /// この OptionGroup を共有しているので、そこでは `--allow-version-skew` が黙って効かない。
    /// **指定したのに効かない形を作らない** —— 効かせられない場所では名指しで断る
    func rejectVersionSkewFlag(in command: String) throws {
        if allowVersionSkew {
            throw ValidationError("--allow-version-skew has no effect on \(command)"
                + " (it applies to the manual drive commands: snapshot/tap/type/swipe/press/"
                + "screenshot/launch/install/terminate)")
        }
    }

    /// `platform`/`port` は non-Optional にしない —— 既定値を持たせると「指定された」と
    /// 「既定のまま」が区別できず、`--profile` との併用禁止のような検査ができなくなる
    /// (`RunRejectionTests` 参照)。既定値が要る箇所はここを通す
    var resolvedPlatform: String { platform ?? "ios" }
    var resolvedPort: UInt16 { port ?? BridgeAPI.defaultPort }

    /// FTFoundationModels/FTCore はこの抽象のみに依存(BridgeClient/AndroidDriver を直接見ない)。
    /// **手動駆動サブコマンド(install/launch/snapshot/tap/type/swipe/press/screenshot/
    /// terminate)だけがここを通る** —— `bridge up`/`bridge status` は `resolvedPort` を
    /// 直接使うので、この探索・版ズレ拒否の影響を受けない。
    /// 宛先解決は MCP(ft_*)と同じ `FTBridgeClient.BridgeTargetResolution` /
    /// `FTAndroid.AndroidTargetResolution` を通す(判定を2つ持たない)
    func makeDriver(overriding platformOverride: String? = nil) async throws -> AppDriver {
        switch platformOverride ?? resolvedPlatform {
        case "ios":
            // 実機ブリッジは 127.0.0.1 に居ない(LAN)か token が要る(usb)。provision が残した
            // 宛先を丸ごと使う(記録が無ければループバック = シミュレータの既定)。
            // **明示 --port は探索しない**ので実機は従来どおり通る
            let resolvedPort: UInt16
            do {
                resolvedPort = try await BridgeTargetResolution.iosPort(
                    explicit: port, log: { ConsoleOut.err($0) })
            } catch let error as BridgeTargetError {
                throw ValidationError(error.errorDescription ?? "\(error)")
            }
            let driver = PortDirectIOSTarget(port: resolvedPort).makeDriver()
            if let skew = await BridgeTargetResolution.versionSkew(driver: driver) {
                guard allowVersionSkew else {
                    throw ValidationError(Self.skewMessage(skew, port: resolvedPort))
                }
                ConsoleOut.err("⚠️ --allow-version-skew: proceeding despite a bridge/host mismatch. "
                               + Self.skewMessage(skew, port: resolvedPort))
            }
            return driver
        case "android":
            do {
                let resolvedSerial = try AndroidTargetResolution.serial(
                    explicit: serial, log: { ConsoleOut.err($0) })
                return try AndroidDriver(serial: resolvedSerial)
            } catch let error as AndroidTargetError {
                throw ValidationError(error.errorDescription ?? "\(error)")
            }
        default:
            throw ValidationError("platform must be ios or android: \(platformOverride ?? resolvedPlatform)")
        }
    }

    /// 版ズレの CLI 向け文言(純粋関数・テスト用)。**判定(running/expected の比較)は
    /// `BridgeVersionSkew`(FTBridgeClient・MCP と共有)** —— ここは対処の言い回しだけ持つ
    /// (MCP は `fleetest-mcp`/`bridge down --all` を名指しする。こちらは `fleetest` の
    /// 再ビルドと、この宛先だけを建て直す `bridge down --port` を名指しする。文言は呼び手ごと)
    static func skewMessage(_ skew: BridgeVersionSkew, port: UInt16) -> String {
        let side = skew.bridgeIsNewer
            ? "the bridge on port \(port) is NEWER than this build (v\(skew.running) > v\(skew.expected)) —"
                + " your fleetest binary is stale, so rebuild it (swift build --product fleetest) or pull"
            : "the bridge on port \(port) is OLDER than this build (v\(skew.running) < v\(skew.expected)) —"
                + " restart it with `fleetest bridge down --port \(port) && fleetest bridge up`"
        return "bridge protocol mismatch: \(side)."
            + " Refusing to operate: a stale bridge answers with the behaviour of its own version."
            + " Pass --allow-version-skew to proceed anyway."
    }
}

// MARK: - doctor

/// 進捗表示の間引きに使う箱。コールバックは @Sendable なので可変値を直接掴めない
private final class ProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    /// 前回から interval 秒経っていれば true(そのとき時刻を進める)
    func tick(interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(last) >= interval else { return false }
        last = Date()
        return true
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Preflight checks for Foundation Models, Xcode and simulators")

    // FM/Apple Intelligence の可否だけを判定して exit code に反映する高速ゲート。
    // setup スキルがビルド直後に人間へ聞かずに自動判定するために使う(FM 不可なら非0で終了)。
    @Flag(name: .long, help: "Only check Apple Intelligence / on-device FM availability and report it via exit code")
    var fmOnly = false

    // ルート解決だけを見る高速ゲート。FM(実呼び出しで数秒・環境によっては失敗)に依存させない
    // ため独立させてある。パス取り違えの切り分けはこれ単体で完結する
    @Flag(name: .long, help: "Only check tool-root / scenario-package root resolution and report it via exit code")
    var rootsOnly = false

    // FMGate を通さず素通しで負荷をかける(FMLoadGenerator.run の doc 参照)。実行中の run と
    // FM の直列化容量を奪い合うので、他に何も走らせていないときに使う
    @Flag(name: .long, help: ArgumentHelp("Load-test Foundation Models (no other checks run). "
        + "FM is a host-wide serialized resource — this competes with any run in progress for it. "
        + "The calls are recorded like any other FM usage, so they also move the FM row "
        + "in the monitor / VSCode toolbar"))
    var fmLoad = false

    // 根拠: 2026-07-22 M2 Ultra 実測でスループットが頭打ちになる最小の並列度
    // (並列度1→0.83 回/秒、5→1.03 回/秒、10→1.02 回/秒で頭打ち)。天井まで埋めるのに要る最小のコスト
    @Option(name: .long, help: "Concurrency for --fm-load (default: 5, the smallest concurrency that saturates the serialized FM queue)")
    var fmLoadConcurrency: Int?

    // 根拠: 実測の天井が約1回/秒なので、中央値が安定する程度の標本(約30件)が取れる最短の秒数
    @Option(name: .long, help: "Duration in seconds for --fm-load (default: 30, enough calls at the ~1/s ceiling for a stable median)")
    var fmLoadSeconds: Double?

    @Flag(name: .long, help: "Load-test with image input (occlusion-guard's path) instead of text")
    var fmLoadVision = false

    // occlusion guard は**リサイズせず**スクリーンショットの切り出しを渡す(最大でスクショ全体
    // ≈1200x2600px)。合成の 64x64 とは推論コストが桁で違うので、本番の寸法で振れるようにする
    @Option(name: .long, help: ArgumentHelp("Image size for --fm-load-vision as WxH (default 64x64). "
        + "Production occlusion crops are screenshot cutouts with no downscaling — up to the full "
        + "screenshot (~1200x2600 on a 3x phone)"))
    var fmLoadImage: String?

    func validate() throws {
        if !fmLoad {
            if fmLoadConcurrency != nil { throw ValidationError("--fm-load-concurrency requires --fm-load") }
            if fmLoadSeconds != nil { throw ValidationError("--fm-load-seconds requires --fm-load") }
            if fmLoadVision { throw ValidationError("--fm-load-vision requires --fm-load") }
            if fmLoadImage != nil { throw ValidationError("--fm-load-image requires --fm-load") }
        } else {
            if fmOnly { throw ValidationError("--fm-load cannot be combined with --fm-only") }
            if rootsOnly { throw ValidationError("--fm-load cannot be combined with --roots-only") }
        }
    }

    func run() async throws {
        if fmLoad {
            try await runFMLoad()
            return
        }
        if rootsOnly {
            // ツール本体が解決できない = ブリッジが起動不能なので非0。シナリオパッケージ側は
            // パッケージ外から実行しても正当なので警告どまり(exit code に反映しない)
            let toolRootResolved = printRoots()
            if !toolRootResolved { throw ExitCode(1) }
            return
        }

        // availability だけでは実呼び出しの可否が分からない(FMDoctor.checkLive の doc 参照)。
        // doctor は「本当に使えるか」を答える場所なので実呼び出しで確認する
        let fm = await FMDoctor.checkLive()
        ConsoleOut.out(fm.available ? "✅ \(fm.detail)" : "❌ \(fm.detail)")
        // **何が止まるかまで書く**(ft_doctor と同じ本文)。受け手向けドキュメントは FM の可否を
        // この経路で確かめろと案内しているので、ここが黙ると「使えない」しか分からない
        if !fm.available { ConsoleOut.out("   " + FMDoctor.unavailableImpact) }
        // **視覚系も実呼び出しで確かめる**。text と vision は独立に死ぬ(実測)ので、text が
        // 通ったことは occlusion-guard が生きている証拠にならない。ここを能力判定だけに
        // していた頃は、vision 全滅の機械で `--fm-only` が 0 を返し、その run の緑が
        // 「守りが効いた緑」だと誤読されていた
        let vision = await FMDoctor.visionCheckLive()
        // macOS が対応していないだけ(死ではない)のときは警告どまり、実呼び出しが落ちたら ❌
        let visionUnsupported = !FMVisionSupport.isSupported
        ConsoleOut.out(vision.available ? "✅ \(vision.detail)" : (visionUnsupported ? "⚠️ " : "❌ ") + vision.detail)
        if fmOnly {
            // 可: 0 / 不可: 1。呼び出し側が理由文字列を stdout から読める。
            // **どちらの経路が死んでいても 1**(片方だけ死ぬのが常態で、片方しか見ないゲートは
            // 「FM は使える」と嘘をつく)。OS 非対応の vision は死に数えない
            if !fm.available || (!vision.available && !visionUnsupported) { throw ExitCode(1) }
            return
        }

        _ = printRoots()

        let xcode = try Shell.run(["xcodebuild", "-version"])
        let xcodeLine = xcode.output.split(separator: "\n").first.map(String.init) ?? "unknown"
        ConsoleOut.out(xcode.status == 0 ? "✅ \(xcodeLine)" : "❌ xcodebuild not found")

        await reportUnmanagedBridges()

        // ランナーをビルドした Xcode/SDK と現在のものの一致確認。Xcode(beta)更新後に
        // 旧ビルドのランナーを使う・逆に新ビルドのランナーを旧ランタイムに載せると、アプリが
        // 実行中に「Application is not running」でクラッシュする(2026-07-21 実害)。
        // 判定は再ビルドの砦と同じ指紋(BridgeLauncher.staleRunnerToolchain)。
        // **成果物の Info.plist は見ない** —— 理由は同関数の doc(テンプレートのコピー)
        if let root = try? RepoRoot.find(),
           let stored = BridgeLauncher.staleRunnerToolchain(repoRoot: root) {
            ConsoleOut.out("⚠️ The XCUITest runner was built with a different toolchain (\(stored)). "
                + "The next bridge start rebuilds it; if the iOS runtime for the new Xcode is missing, "
                + "install it first (xcodebuild -downloadPlatform iOS)")
        }

        let sims = try Shell.run(["xcrun", "simctl", "list", "devices", "booted"])
        let booted = sims.output.split(separator: "\n")
            .filter { $0.contains("(Booted)") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if booted.isEmpty {
            ConsoleOut.out("⚠️  No booted simulators (bridge up will boot one automatically)")
        } else {
            ConsoleOut.out("✅ Booted simulators: \(booted.joined(separator: ", "))")
        }

        if let bootedDevices = try? SimulatorCatalog.devices().filter(\.booted) {
            for device in bootedDevices {
                // 未設定キーは defaults read が非0で終了する(未設定 = 無効相当として扱う)
                let read = try? Shell.run([
                    "xcrun", "simctl", "spawn", device.udid,
                    "defaults", "read", "com.apple.Accessibility", "ReduceMotionEnabled",
                ])
                let enabled = read?.status == 0
                    && read?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                if !enabled {
                    ConsoleOut.out("     ⚠️ \(device.name): Reduce Motion is off. "
                          + "Runs are slower because of animation waits (it is enabled automatically on the next bridge start)")
                }
            }
        }

        let xcodegen = try Shell.run(["which", "xcodegen"])
        ConsoleOut.out(xcodegen.status == 0
              ? "✅ xcodegen: \(xcodegen.output.trimmingCharacters(in: .whitespacesAndNewlines))"
              : "❌ xcodegen is required: brew install xcodegen")

        if let android = try? AndroidDriver() {
            let devices = try Shell.run([android.adbPath, "devices"])
            let connected = devices.output.split(separator: "\n").dropFirst()
                .filter { $0.contains("\tdevice") }
            ConsoleOut.out("✅ adb: \(android.adbPath)"
                  + (connected.isEmpty ? " (no devices connected)" : " (\(connected.count) connected)"))
            if let apk = try? AndroidDriver.locateBridgeAPK() {
                ConsoleOut.out("   ✅ Bridge APK: \(apk.path)")
            } else {
                ConsoleOut.out("   ❌ Bridge APK not found (generate it with AndroidRunner/build.sh)")
            }
            // AVD の新規作成(モニターの「デバイスを追加」/ api create-device)にだけ要る。
            // 既存 AVD で実行するぶんには不要なので警告どまり
            if let avdmanager = AndroidSDKLocator.findAVDManager() {
                ConsoleOut.out("   ✅ avdmanager: \(avdmanager.path)")
            } else {
                ConsoleOut.out("   ⚠️ \(AndroidSDKLocator.avdManagerMissingMessage). "
                      + "New AVDs cannot be created (running on existing AVDs is unaffected). "
                      + AndroidSDKLocator.avdManagerInstallHint)
            }
            for line in connected {
                guard let serial = line.split(separator: "\t").first.map(String.init) else { continue }
                // 高速スナップショット用ブリッジ(未導入でも初回操作時に自動導入・起動される)
                if let driver = try? AndroidDriver(serial: serial) {
                    ConsoleOut.out("   ・ \(serial): \(driver.bridgeDoctorSummary())")
                    if let warning = driver.animationScaleWarning() {
                        ConsoleOut.out("     ⚠️ \(warning)")
                    }
                }
            }
        } else {
            ConsoleOut.out("⚠️ adb not found (set ANDROID_HOME if you use Android)")
        }
    }

    /// 2つのルートを表示し、ツール本体を解決できたかを返す。外部パッケージ構成では別ディレクトリに
    /// なり、取り違えると「InAppBridge/build.sh が無い」「TestProjects/ が見えない」で詰まる(実害あり)
    /// このリポジトリの管理下に無いブリッジ(別クローン起動 / 版が古い)の報告と、
    /// **証拠が決定的なものだけ**の自動停止(処遇は UnmanagedBridgeTriage が唯一の判定者):
    /// 自リポジトリの旧版・起動元リポジトリが消滅したゾンビ → 停止 /
    /// 別の実在ワークスペースの所有・起動元不明 → 報告のみ(他人の資産を勝手に殺さない)。
    ///
    /// 放置すると**ポートとシミュレータを握ったまま永久に残る**: provision の stale 掃除は
    /// 供給対象デバイスの分しか見ない(BridgeProvisioner の sameDevice 条件)ので、
    /// プロファイル外のデバイスに残った旧版ブリッジは誰も片付けない。
    /// 実害: protocolVersion 4 のランナーが 7 時間 22 分ポート 8127 とシミュレータを占有した
    /// (無通信 TTL 導入後は最長でも TTL で消えるが、旧版ブリッジには TTL が無い)。
    private func reportUnmanagedBridges() async {
        guard let root = try? RepoRoot.find() else { return }
        let stateDir = root.appendingPathComponent(".fleetest")
        var findings: [String] = []
        var reaped: [String] = []
        for port in BridgeAPI.defaultPort...(BridgeAPI.defaultPort + 31) {
            guard let status = BridgeLauncher.probeForeignBridge(port: port, timeout: 0.4)
            else { continue }
            let pidPath = stateDir.appendingPathComponent("bridge-\(port).pid")
            let inAppPath = InAppBridgeState.url(stateDir: stateDir, port: port)
            let hasPid = FileManager.default.fileExists(atPath: pidPath.path)
            let hasInApp = FileManager.default.fileExists(atPath: inAppPath.path)
            let stale = status.protocolVersion != BridgeAPI.bridgeProtocolVersion
            let version = status.protocolVersion.map(String.init) ?? "?"
            let label = "port \(port): \(status.device)(v\(version))"
            // 「いつから放置か」の診断(自己申告の idleSeconds。この probe 自体は数えない)
            let idle = status.idleSeconds.map { $0 >= 60 ? ", idle \(Int($0 / 60))m" : "" } ?? ""

            switch UnmanagedBridgeTriage.decide(
                ownerRepo: status.ownerRepo,
                ownerExists: status.ownerRepo.map {
                    FileManager.default.fileExists(atPath: $0) } ?? false,
                isOwnRepo: status.ownerRepo == root.path,
                hasStateFile: hasPid || hasInApp,
                stale: stale) {
            case .skipHealthy:
                continue
            case .reapOwnStale:
                // 自分の資産の旧版。in-app はアプリごと終了、xcuitest は pid ファイル経由で停止
                if hasInApp {
                    InAppBridgeState.terminateAndRemove(at: inAppPath)
                    reaped.append("\(label) — stale version (expected v\(BridgeAPI.bridgeProtocolVersion)) owned by this repo")
                } else if let pid = Self.pidFromFile(pidPath), BridgeLauncher.reapRunnerProcess(pid: pid) {
                    try? FileManager.default.removeItem(at: pidPath)
                    reaped.append("\(label) — stale version (expected v\(BridgeAPI.bridgeProtocolVersion)) owned by this repo")
                } else if let pid = status.ownerPid.map(Int32.init), BridgeLauncher.reapRunnerProcess(pid: pid) {
                    try? FileManager.default.removeItem(at: pidPath)
                    reaped.append("\(label) — stale version (expected v\(BridgeAPI.bridgeProtocolVersion)) owned by this repo")
                } else {
                    findings.append("   - \(label) — stale version but could not be stopped (check `lsof -ti :\(port)`)")
                }
            case .reapOrphan(let owner):
                if let pid = status.ownerPid.map(Int32.init), BridgeLauncher.reapRunnerProcess(pid: pid) {
                    reaped.append("\(label) — its owner is gone (\(owner))")
                } else {
                    findings.append("   - \(label) — its owner is gone (\(owner)) and it could not be stopped via ownerPid. "
                        + "Kill the process shown by `lsof -ti :\(port)`")
                }
            case .reportForeign(let owner):
                findings.append("   - \(label)\(idle) — owned by another workspace: \(owner). "
                    + "Run `fleetest bridge down --port \(port)` from that clone")
            case .reportUnknown:
                findings.append("   - \(label)\(idle) — unknown owner (an old bridge with no self-report). "
                    + "Kill the process from `lsof -ti :\(port)`; on iOS also run "
                    + "`xcrun simctl terminate <udid> com.example.ftrunner.uitests.xctrunner`")
            }
        }
        if !reaped.isEmpty {
            ConsoleOut.out("✂️ Stopped bridges that will not be reused:")
            reaped.forEach { ConsoleOut.out("   - \($0)") }
        }
        if findings.isEmpty {
            if reaped.isEmpty { ConsoleOut.out("✅ No unmanaged or stale bridges") }
        } else {
            ConsoleOut.out("⚠️ Bridges that will not be reused are still running (they hold ports and devices):")
            findings.forEach { ConsoleOut.out($0) }
        }
    }

    private static func pidFromFile(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func printRoots() -> Bool {
        var resolved = false
        switch Result(catching: { try RepoRoot.find() }) {
        case .success(let root):
            ConsoleOut.out("✅ Tool root (bridge assets): \(root.path)")
            resolved = true
        case .failure(let error):
            ConsoleOut.out("❌ Cannot determine the tool root: \(error.localizedDescription)")
        }
        if let packageRoot = ScenarioHost.packageRoot() {
            ConsoleOut.out("✅ Scenario package (TestProjects/): \(packageRoot.path)")
        } else {
            ConsoleOut.out("⚠️ No scenario package (Package.swift) found above the current directory"
                + " (set FT_PACKAGE_ROOT to point at it explicitly)")
        }
        return resolved
    }

    /// FMLoadGenerator を回し、実測を出す。他のチェックは行わない(fmLoad の validate() 参照)。
    /// **この負荷は実行中の run と FM の直列化容量を奪い合う**(FMGate を通さないため)ので、
    /// 単独で回すことが前提
    private func runFMLoad() async throws {
        let seconds = fmLoadSeconds ?? 30
        let concurrency = fmLoadConcurrency ?? 5
        if seconds <= 0 { throw ValidationError("--fm-load-seconds must be greater than 0") }
        if concurrency < 1 { throw ValidationError("--fm-load-concurrency must be at least 1") }

        // 安価な availability チェックを先に払う。呼べないと分かっているのに直列化ロックへ
        // 何十回も並べて投げても、頭打ち実測ではなく可用性の失敗を測るだけになる
        let base = FMDoctor.check()
        guard base.available else {
            ConsoleOut.out("❌ \(base.detail)")
            throw ExitCode(1)
        }

        var imageSize: (width: Int, height: Int)?
        if let raw = fmLoadImage {
            let parts = raw.lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
                throw ValidationError("--fm-load-image must be WxH (e.g. 1206x2622)")
            }
            guard fmLoadVision else { throw ValidationError("--fm-load-image requires --fm-load-vision") }
            imageSize = (w, h)
        }
        let shape = fmLoadVision ? "vision \(imageSize.map { "\($0.width)x\($0.height)" } ?? "64x64")" : "text"
        ConsoleOut.out("FM load: \(shape), \(Int(seconds))s x concurrency \(concurrency)")
        let progressClock = ProgressClock()
        let summary = await FMLoadGenerator.run(
            seconds: seconds, concurrency: concurrency, vision: fmLoadVision, imageSize: imageSize
        ) { count in
            // 毎回書くと1行に数百の断片が並ぶ(20秒 × 約8回/秒)。目的は「進んでいる」ことの提示だけ
            guard progressClock.tick(interval: 1) else { return }
            ConsoleOut.err(Data("\r  ...\(count) calls".utf8))
        }
        ConsoleOut.err(Data("\r".utf8))

        // calls=0 only happens when vision was requested but FMVisionSupport says no (the run
        // never dispatched a single call) — report and fail rather than print a fake all-zero summary
        if summary.calls == 0, let reason = summary.firstError {
            ConsoleOut.out("❌ \(reason)")
            throw ExitCode(1)
        }

        ConsoleOut.out(String(format: "  calls         %5d", summary.calls))
        ConsoleOut.out(String(format: "  failures      %5d", summary.failures))
        // **「FM の天井」を断定しない**。この数字は FMGate/FMLock を通していないので FM 単体の能力で、
        // production の FM 呼び出しは全部あの門で許可枠(既定5・FT_FM_CONCURRENCY で調整)に絞られる
        // (= run 中に見えるレートとは別物)。天井を文言に焼き付けると、環境が変わったときに
        // 数字と矛盾する断定を並べて出すことになる
        ConsoleOut.out(String(format: "  throughput    %.2f calls/s", summary.throughputPerSecond))
        ConsoleOut.out("  latency       p50 \(summary.p50Ms)ms / max \(summary.maxMs)ms")
        if summary.failures > 0, let firstError = summary.firstError {
            ConsoleOut.out("  first error: \(firstError)")
        }
        ConsoleOut.out("Note: this bypasses FMGate/FMLock, which cap every FM call a run makes to a shared"
            + " concurrency limit, so it measures FM itself — not the rate a run can reach.")
        ConsoleOut.out("This load is visible in the monitor's FM row too "
            + "(FMHealth.record feeds ~/.fleetest/fm-usage/<pid>.json, which `api host-metrics` reads).")

        if summary.calls > 0, summary.failures == summary.calls {
            throw ExitCode(1)
        }
    }
}

// MARK: - bridge

struct Bridge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the XCUITest bridge (runner)",
        subcommands: [Up.self, Down.self, Status.self])

    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the bridge and keep it resident (iOS: a simulator runner / Android: an on-device server)")

        @Option(help: "Simulator device name (iOS only)")
        var device: String = "iPhone 17 Pro"

        @Flag(help: "Skip build-for-testing when it is already built (iOS only)")
        var skipBuild = false

        @Flag(help: "Also build and install SampleApp (iOS only)")
        var withSampleApp = false

        @Flag(help: "Treat --device as the UDID of a physical iOS device (the Identifier from xcrun devicectl list devices)")
        var physical = false

        @OptionGroup var driverOptions: DriverOptions

        func validate() throws { try driverOptions.rejectVersionSkewFlag(in: "bridge up") }

        func run() async throws {
            if driverOptions.resolvedPlatform == "android" {
                // serial 省略時は接続中の全デバイス(8台並列前のプリウォーム用)
                for serial in try AndroidBridgeCLI.serials(only: driverOptions.serial) {
                    let driver = try AndroidDriver(serial: serial)
                    ConsoleOut.out("→ Starting the Android bridge: \(serial)")
                    try await driver.resetAndEnsureBridge()
                    ConsoleOut.out("✅ \(serial): \(driver.bridgeDoctorSummary())")
                }
                return
            }
            let root = try RepoRoot.find()
            let launcher = BridgeLauncher(repoRoot: root, device: device, port: driverOptions.resolvedPort,
                                          physical: physical)

            ConsoleOut.out("→ Generating the project (xcodegen)...")
            try launcher.generateProjectIfNeeded()

            if !skipBuild {
                ConsoleOut.out("→ build-for-testing (the first run takes several minutes)...")
                try launcher.buildForTesting()
            }
            if withSampleApp {
                ConsoleOut.out("→ Building and installing SampleApp...")
                try launcher.installSampleApp()
            }
            // 起動は provision() 経由(直接 startDetached しない)。同一シミュレータに XCUITest
            // ランナーは1本しか同居できず(全ポート共通 bundle id のため2本目が先代を蹴り出し双方
            // signal kill で死ぬ)、直接起動は同一デバイスへの二重起動を防げない。provision() は
            // 稼働中ブリッジのスキャン→版一致なら再利用/旧版なら停止して起動し直すをまとめて行う
            // (モニター保持中でも拒否せず再利用・起動する=テスト/操作優先)。
            // 実機は必ず UDID 指定(形状推測はしない。実機 UDID はシミュレータ UUID と形が違う)
            let isUDID = physical || (device.count == 36 && device.split(separator: "-").count == 5)
            let spec = DeviceSpec(
                name: device,
                kind: physical ? .physical : nil,
                simulator: isUDID ? nil : device,
                udid: isUDID ? device : nil,
                port: driverOptions.resolvedPort,
                engine: "xcuitest")
            let provisioned = try await BridgeProvisioner(repoRoot: root)
                .provision(devices: [(spec.name, spec)], log: { ConsoleOut.out($0) })
            // provision() は失敗時に throw する(空配列で正常復帰はしない)ため、first は常に存在する
            let port = provisioned.first?.port ?? driverOptions.resolvedPort
            // provision は同一デバイスの稼働中ブリッジを preferred(--port)を無視して再利用する。
            // 固定ポート前提のスクリプトが :driverOptions.resolvedPort を叩いて外さないよう、差異を明示する
            if port != driverOptions.resolvedPort {
                ConsoleOut.out("⚠️ Reused the running bridge on this device (port \(port)) instead of the requested/default "
                    + "port \(driverOptions.resolvedPort). To rebuild on port \(driverOptions.resolvedPort), stop it first "
                    + "with `fleetest bridge down --port \(port)` and run again.")
            }
            let host = provisioned.first?.host ?? BridgeEndpoint.loopbackHost
            ConsoleOut.out("✅ Bridge ready: http://\(host):\(port)")
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the bridge")

        @Option(name: .long, help: "Port of the bridge to stop (iOS only)")
        var port: UInt16 = BridgeAPI.defaultPort

        @Flag(help: "Stop the bridges on every port (iOS only)")
        var all = false

        @Option(help: "Target platform: ios / android")
        var platform: String = "ios"

        @Option(help: "Android device serial (defaults to every connected device)")
        var serial: String?

        func run() async throws {
            if platform == "android" {
                for serial in try AndroidBridgeCLI.serials(only: serial) {
                    try AndroidDriver(serial: serial).stopBridge()
                    ConsoleOut.out("✅ Stopped the Android bridge: \(serial)")
                }
                return
            }
            let root = try RepoRoot.find()
            if all {
                let stopped = BridgeLauncher.stopAll(repoRoot: root, skipPhysical: false)
                ConsoleOut.out(stopped.isEmpty
                      ? "No bridges are running"
                      : "✅ Stopped bridges (port: \(stopped.joined(separator: ", ")))")
            } else {
                // physical は stop() が見ない(kind を知らない経路からも止められるよう、
                // stop() 側が条件分岐しない宣言をしている)ので false でよい
                let launcher = BridgeLauncher(repoRoot: root, port: port, physical: false)
                try launcher.stop()
                ConsoleOut.out("✅ Stopped the bridge (port: \(port))")
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the bridge status")

        @OptionGroup var driverOptions: DriverOptions

        func validate() throws { try driverOptions.rejectVersionSkewFlag(in: "bridge status") }

        func run() async throws {
            if driverOptions.resolvedPlatform == "android" {
                for serial in try AndroidBridgeCLI.serials(only: driverOptions.serial) {
                    let driver = try AndroidDriver(serial: serial)
                    ConsoleOut.out("\(serial): \(driver.bridgeDoctorSummary())")
                }
                return
            }
            // **1本だけ見て「何も無い」と言わない**(2026-09-04 の実害): 既定ポートへ問い合わせて
            // 落ちるだけの実装では、**8本動いている状態で**「nothing listening / アプリが
            // 落ちたのだろう」と報告していた(既定の 8123 が空いていただけ)。Android 側は
            // 元から接続中の全 serial を列挙しており、非対称でもあった。**動いているものを全部出す**
            let found = await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
            ConsoleOut.out(BridgeStatusReport.render(found, requested: driverOptions.resolvedPort))
        }
    }
}

/// `fleetest bridge status`(iOS)の表示。**純関数にしてあるのはテストのため** ——
/// 走査そのものはブリッジが要るのでテストから通せない
enum BridgeStatusReport {
    static func render(_ found: [BridgeDiscovery.Found], requested: UInt16) -> String {
        guard !found.isEmpty else {
            return "no bridge is running on this machine"
                + " (ports \(BridgeDiscovery.scannedPortsDescription) were scanned)."
                + " Start one with: fleetest bridge up"
        }
        // **要求されたポートに印を付ける**(--port を渡した人が自分の1本を見失わないため)
        return found.sorted { $0.port < $1.port }.map { entry in
            let mark = entry.port == requested ? "→ " : "  "
            let udid = entry.udid.map { " udid \($0)" } ?? ""
            return "\(mark)port \(entry.port): \(entry.device) (\(entry.engine))\(udid)"
        }.joined(separator: "\n")
    }
}

enum AndroidBridgeCLI {
    static func serials(only serial: String?) throws -> [String] {
        if let serial { return [serial] }
        let adbPath = try AndroidDriver.findADB()
        let devices = try Shell.run([adbPath, "devices"])
        let serials = devices.output.split(separator: "\n").dropFirst()
            .filter { $0.contains("\tdevice") }
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
        guard !serials.isEmpty else {
            throw ValidationError("no Android device is connected (check adb devices)")
        }
        return serials
    }
}

// MARK: - 手動駆動コマンド

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install an app from a package file (iOS: .app bundle / Android: .apk or .apks)")

    @Argument(help: "Path to the package file (iOS: .app bundle / Android: .apk, or .apks via bundletool)")
    var packagePath: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        guard FileManager.default.fileExists(atPath: packagePath) else {
            throw ValidationError("package file not found: \(packagePath)")
        }
        try await driverOptions.makeDriver().install(packagePath: packagePath)
        ConsoleOut.out("✅ Installed: \(packagePath)")
    }
}

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Launch the app under test")

    @Argument(help: "App bundle identifier (e.g. com.example.sampleapp)")
    var bundleID: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().launch(bundleID: bundleID)
        ConsoleOut.out("✅ Launched: \(bundleID)")
    }
}

struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the accessibility tree of the current screen (compressed)")

    @Flag(help: "Print the raw JSON")
    var json = false

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let snapshot = try await driverOptions.makeDriver().snapshot()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            ConsoleOut.out(String(data: try encoder.encode(snapshot), encoding: .utf8)!)
        } else {
            ConsoleOut.out(SnapshotRenderer.render(snapshot))
        }
    }
}

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tap an element or a coordinate")

    @Option(help: "Reference number from snapshot")
    var ref: Int?

    @Option(help: "X coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var x: Double?

    @Option(help: "Y coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var y: Double?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        if let ref {
            try await driverOptions.makeDriver().tap(ref: ref)
            ConsoleOut.out("✅ tap [\(ref)]")
        } else if let x, let y {
            try await driverOptions.makeDriver().tap(x: x, y: y)
            ConsoleOut.out("✅ tap (\(x), \(y))")
        } else {
            throw ValidationError("specify either --ref or --x/--y")
        }
    }
}

struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text (with --ref, taps the element first)")

    @Option(help: "Reference number of the target field (defaults to the focused element)")
    var ref: Int?

    @Argument(help: "Text to type")
    var text: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().type(ref: ref, text: text)
        ConsoleOut.out("✅ type \"\(text)\"")
    }
}

struct Swipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Swipe")

    @Argument(help: "Direction: up / down / left / right")
    var direction: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        guard let dir = FTSwipeDirection(rawValue: direction) else {
            throw ValidationError("direction must be one of up / down / left / right")
        }
        try await driverOptions.makeDriver().swipe(dir)
        ConsoleOut.out("✅ swipe \(direction)")
    }
}

struct Press: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Long-press an element")

    @Option(help: "Reference number")
    var ref: Int

    @Option(help: "Press duration in seconds")
    var holdSeconds: Double = 1.0

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().press(ref: ref, duration: holdSeconds)
        ConsoleOut.out("✅ press [\(ref)] \(holdSeconds)s")
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a screenshot")

    @Option(name: .shortAndLong, help: "Output PNG path")
    var output: String = "screenshot.png"

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let data = try await driverOptions.makeDriver().screenshot()
        try data.write(to: URL(fileURLWithPath: output))
        ConsoleOut.out("✅ Saved: \(output) (\(data.count) bytes)")
    }
}

struct Terminate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Terminate the app under test")

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().terminate()
        ConsoleOut.out("✅ Terminated")
    }
}

// MARK: - 実行コマンド

struct RunScenarios: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run Swift DSL scenarios (TestProjects/<name>/scenarios/). FM only steps in on failure")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json). Includes device provisioning and auto-install. Cannot be combined with --platform/--port/--serial/--app-id")
    var profile: String?

    @Option(name: .customLong("scenario"), parsing: .upToNextOption,
            help: "Scenario IDs to run (Class.method; a class name alone runs all of its scenarios). Repeatable; defaults to all. @Deleted / @Draft scenarios run only on an exact match")
    var scenarios: [String] = []

    @Option(name: .customLong("folder"), parsing: .upToNextOption,
            help: "Scenario folders to run (subfolders directly under scenarios/). Repeatable; can be combined with --scenario and --failed")
    var folders: [String] = []

    /// キーはプロファイル JSON のキーそのもの(kebab 変換しない)。**共有フラグ**(`fleetest api run`
    /// にも同じ口があるので `RunCommandFlagParityTests` の runOnly/apiOnly には入れない)。
    /// 上書きは `ProfileResolver.resolve` / `--profile` 無しの直接実行の両方で
    /// `RunProfileDocument.applyingOverrides` を通る唯一の経路(FTCore/RunProfile.swift)。
    /// 値の型はキーの宣言型に従う(Bool/Int/Double/String。パース失敗は型を名指しでエラーにする。
    /// 検証は `RunProfileSetOverride.parse`。validate() が呼ぶ)。
    /// **プロファイルの devices 一覧・供給工程に依存するキー**(`RunProfileDocument.profileOnlyKeys`:
    /// iosInappEngine/updateWebView/wipeDataOnBloat/recoverCpuFallbackToGpu/app/machine/locale/
    /// wipeDataThresholdGB)は `--profile` が無いと run() のプロファイル無し分岐でエラーにする
    /// (黙って無視しない)。`record` は devices に依存しないが、単一接続(`--port` 未指定/1個)の
    /// 経路では別途エラーにする(RunOrchestrator の録画セッションが無い。run() 参照)。
    /// **`reportDir` は `--report-dir` と同時指定するとエラー**(黙ってどちらかを勝たせない。
    /// validate() 参照)
    @Option(name: .customLong("set"),
            help: ArgumentHelp("Override one field of the run profile document for this run only "
                + "(repeatable): <key>=<value>, where <key> is exactly the run profile JSON key and "
                + "<value> matches that key's type (e.g. --set falsePositiveCheck=false "
                + "--set reportDir=/tmp/out). Keys that need a run profile's device list/supply "
                + "pipeline (iosInappEngine, updateWebView, wipeDataOnBloat, recoverCpuFallbackToGpu, "
                + "app, machine, locale, wipeDataThresholdGB) need --profile. The run profile keys "
                + "\"app\"/\"machine\" (an app/machine *profile* name) are unrelated to this command's "
                + "own --app-id/--runner flags. Cannot combine reportDir with --report-dir. "
                + "devices/remoteControl are lists/objects and cannot be set this way; edit the run "
                + "profile JSON instead"))
    var setOverrides: [String] = []

    @Flag(name: .customLong("dry-run"),
          help: "Enumerate and validate the steps without touching a device (No-Load-Run). Catches selector syntax errors, unreachable scenes and expectation blocks with no assertions")
    var dryRun = false

    @Flag(name: .customLong("no-lpt"),
          help: "Disable LPT ordering (longest past runtime first) and dispatch in scenario ID order")
    var noLPT = false

    @Option(name: .customLong("lpt-history-runs"),
            help: "Number of past runs to read for LPT ordering (newest first, default 5)")
    var lptHistoryRuns: Int?

    @Flag(help: "Run only the scenarios that failed last time (results are recorded in .fleetest/last-results/ on every run)")
    var failed = false

    @Option(name: .customLong("report-dir"),
            help: "Directory to write reports to (defaults to TestProjects/<name>/reports). Cannot combine with --set reportDir=...")
    var reportDir: String?

    @Option(name: .customLong("port"),
            help: "Bridge port for running iOS scenarios in parallel. Repeatable (--port 8123 --port 8124); each port must already have a bridge up on a separate device")
    var ports: [UInt16] = []

    @Flag(name: .customLong("skip-build"), help: "Skip the swift build before running")
    var skipBuild = false

    @Flag(help: "Suppress step lines and print only the summary (for CI and agents)")
    var quiet = false

    @Option(help: "Write a JUnit XML report of this run to the given path (for CI test reporting)")
    var junit: String?

    /// 受け付ける2つの形(machine = 登録簿の名前 = ローカルエイリアス、host = ホスト名 / IP)の
    /// 解決は RemoteHostRegistry.resolve に委譲する(ApiRunCommand の同名オプションと同じ規律)
    @Option(name: .customLong("runner"), help: ArgumentHelp(
        "Dispatch this run to a remote runner: a registered machine name (fleetest remote machines) "
        + "or a raw user@host/host. Requires --profile"))
    var runner: String?

    @Option(name: .customLong("remote-dir"),
            help: "Runner-only base directory on the remote host (holds its own clone and workspace; default: the host registry's entry, or ~/fleetest-runner). Must NOT point at an existing local install of foundation-tester")
    var remoteDir: String?

    @Option(name: .customLong("remote-timeout"),
            help: "Timeout in seconds for the whole remote dispatch (default: auto, sized from the scenario count; see docs/remote-runner.md)")
    var remoteTimeout: Int?

    @Option(name: .customLong("remote-artifacts"),
            help: "Collect recordings and run logs (results/) from the remote after the run: collect (default) or on-demand (leave them on the remote; docs/remote-runner.md)")
    var remoteArtifacts: String = "collect"

    @Flag(name: .customLong("performance"),
          help: "Performance-testing mode (requires --profile or --fleet): if a dead lane cannot be revived before the run starts, fail instead of dropping it and continuing on the remaining lanes. iOS lanes are built before the run starts (no late join) so a missing one is reported before the run, not in the middle of it")
    var performanceMode = false

    @Option(help: ArgumentHelp("Dispatch this run across a fleet of hosts in parallel: "
        + "profiles/fleets/<name>.json (docs/remote-runner.md §13). Each entry runs as its own "
        + "child process, with output lines prefixed by the entry's host name. Mutually exclusive "
        + "with --runner/--profile/--port/--failed/--report-dir/--skip-build. --junit is supported: "
        + "each entry's report is merged into one file (docs/remote-runner.md §8). Experimental"))
    var fleet: String?

    @Flag(help: ArgumentHelp("With --fleet: distribute the scenario set across the fleet's entries "
        + "(LPT bin packing by past duration; docs/remote-runner.md §8) instead of running the same "
        + "set on every entry. Requires a local build+scenario list to resolve the assignment "
        + "(skipped by plain --fleet), and resolves each entry's platform from its run profile's "
        + "devices. Entries assigned 0 scenarios are not dispatched. Experimental"))
    var split = false

    @Flag(name: .customLong("force-lock"),
          help: ArgumentHelp("Steal a remote host's dispatch.lock instead of failing fast when another dispatch "
            + "already holds it (docs/remote-runner.md §5). Needs a run profile, --runner or --fleet"))
    var forceLock = false

    @Option(name: .customLong("wait-lock"),
            help: ArgumentHelp("Instead of failing fast, poll until a remote host's dispatch.lock is released, "
              + "up to this many seconds (docs/remote-runner.md §5). Needs a run profile, --runner or --fleet. "
              + "Cannot be combined with --force-lock"))
    var waitLock: Int?

    /// ブロードキャスト実行。warmup のように「全デバイスがそれぞれ準備される」
    /// ことが目的の run 向け。分配だけを `ScenarioDispatch.broadcast` に差し替え、他は通常 run
    /// (ProfileRunner.run)と同じ経路。**--profile が要る**(レーン = プロファイルのデバイス)
    @Flag(name: .customLong("broadcast"),
          help: ArgumentHelp("Run the selected scenarios once on EVERY device of the run profile "
            + "(broadcast) instead of sharing them out across the devices — e.g. a warm-up that must "
            + "touch each device. Needs --profile; --device narrows the set of devices. Provisioning, "
            + "auto-install, setup/teardown hooks (once per run), staggered start, lane revival and "
            + "reports are the same as a normal run. Results: one scenarios/*.json per (scenario, device), "
            + "told apart by their worker field"))
    var broadcast = false

    @Option(name: .customLong("device"), parsing: .upToNextOption,
            help: ArgumentHelp("Run on only these devices of the run profile (device names as written in "
                + "the machine profile). Repeatable; defaults to every device the run profile lists. "
                + "Used by the per-host sub-runs when one run profile spans devices on several machines "
                + "(docs/remote-runner.md §13)"))
    var devices: [String] = []

    /// **どの機械のデバイスを使うか**。`--device` は名前でしか絞れないが、一意なのは (host, name)
    /// なので、名前だけだと別の機械の同名デバイスまで掴む(docs/remote-runner.md §13)。
    /// マシン別サブ実行が自分で付ける値で、手で打つものではない
    @Option(name: .customLong("device-machine"),
            help: ArgumentHelp(
                "Only use the devices assigned to this machine (\"local\" or a registered host name). "
                + "Set by the per-host sub-runs; not for hand use",
                visibility: .hidden))
    var deviceMachine: String?

    /// 同じ実行から分かれた run を束ねる鍵(FTCore.RunMetaRecord.runGroup)。**発行は
    /// マシン別サブ実行の親だけ**で、子は受け取った値をそのまま run.json に書く。手で打つものではない
    @Option(name: .customLong("run-group"),
            help: ArgumentHelp(
                "Group key shared by the per-machine sub-runs of one execution. "
                + "Set by the per-host sub-runs; not for hand use",
                visibility: .hidden))
    var runGroup: String?

    /// **手で打つものではない**。RemoteRunDispatcher がミラー後の絶対パスを渡す
    /// (Sources/FTRemote/RemoteDispatch.swift の RemoteRunArgs.build)。プロファイルの
    /// `remoteControl.workspace` を上書きし、appPath のインストール先(ステージ先。原本の解決基準は
    /// 常にリポジトリルートで不変)をそちらへ切り替える(ProfileResolver.resolve の
    /// workspaceOverride / WorkspaceAppStaging 参照)
    @Option(help: ArgumentHelp(
        "Override this run profile's remoteControl.workspace (where the staged appPath package is "
        + "installed from). Set by the remote dispatcher on the far side; not for hand use",
        visibility: .hidden))
    var workspace: String?

    /// `@TestClass(app:)` を書かないシナリオを **実行プロファイル無し**で回すときの逃げ道。
    /// --profile があればそちらのアプリプロファイルから解決されるので併用不可(validate() 参照)
    @Option(name: .customLong("app-id"),
            help: "Default app (bundle ID / package name) for scenarios that declare no @TestClass(app:). Cannot be combined with --profile (the app profile supplies the bundle ID)")
    var appID: String?

    @Option(help: "Target platform: ios / android (default ios)")
    var platform: String?

    @Option(help: "Android device serial (adb -s; defaults to the only connected device)")
    var serial: String?

    /// `platform` は non-Optional にしない —— 既定値を持たせると「指定された」と「既定のまま」が
    /// 区別できず、`--profile` との併用禁止のような検査ができなくなる(DriverOptions と同じ規律)
    var resolvedPlatform: String { platform ?? "ios" }

    func validate() throws {
        let parsed: [String: RunProfileSetValue]
        do { parsed = try RunProfileSetOverride.parse(setOverrides) }
        catch { throw ValidationError(error.localizedDescription) }
        // 専用フラグと同じキーの `--set` は黙ってどちらかを勝たせない(--profile の有無を問わない)
        if let message = RunProfileDocument.flagOverrideCollision(
            flag: "--report-dir", key: "reportDir", flagIsSet: reportDir != nil, overrides: parsed) {
            throw ValidationError(message)
        }
        // --profile 無しのときだけ判定できる(デバイス一覧・録画基盤が無い経路。run() が
        // build 後にもう一度これを検査すると約12秒のビルドを無駄に払う。引数だけで決まるので
        // ここへ寄せる)。**--fleet は除く**(各エントリが自分の --profile を持つので、
        // ここでの「プロファイル無し」判定は誤り。dispatchToFleet は素通しで転送する)。
        // **--dry-run も除く**(デバイスにも録画にも触れないので --set はそもそも使われない。
        // run() が info 注記を出すだけで、この検査までは到達しない)
        if profile == nil, fleet == nil, !dryRun {
            let unsupported = Set(parsed.keys).intersection(RunProfileDocument.profileOnlyKeys).sorted()
            guard unsupported.isEmpty else {
                throw ValidationError("--set \(unsupported.joined(separator: ", ")) needs --profile"
                    + " (there are no devices from a run profile to apply"
                    + " \(unsupported.count == 1 ? "it" : "them") to)")
            }
            // 単一接続の runSequential は RunOrchestrator を経由しないため録画できない
            // (FTCore.RunProfileDocument.recordNeedsRejecting 参照)。--port を2つ以上渡せば
            // runParallel = RunOrchestrator 経由になり録画できる
            let noProfileSettings = DeviceIndependentRunSettings.resolve(
                DeviceIndependentRunSettings.profileLessBase.applyingOverrides(parsed))
            let iosPorts: [UInt16] = ports.isEmpty ? [BridgeAPI.defaultPort] : ports
            if RunProfileDocument.recordNeedsRejecting(record: noProfileSettings.record,
                                                        hasRecordingSession: iosPorts.count > 1) {
                throw ValidationError("--set record=true needs --profile, or --port given more than"
                    + " once (a single connection here runs scenarios directly; there is no"
                    + " recording session for --set record to attach to)")
            }
        }
        if profile != nil,
           platform != nil || !ports.isEmpty || serial != nil {
            throw ValidationError("--profile cannot be combined with --platform/--port/--serial")
        }
        if profile != nil, appID != nil {
            throw ValidationError("--app-id cannot be combined with --profile (the app profile supplies the bundle ID)")
        }
        if performanceMode, profile == nil, fleet == nil {
            throw ValidationError("--performance requires --profile or --fleet")
        }
        // 明示 --runner("local" を除く)は --profile が無いと dispatchToRemoteHost の冒頭で
        // 必ず落ちる。マシンプロファイル経由の自動ディスパッチは --profile がある側でしか
        // 見ないので、ここは引数だけから決まる(ファイル I/O が要らない = validate() に置ける)。
        // **api run と同じ規則・同じ文言**(RunRejectionParityTests が両者の一致を固定する)
        if profile == nil, fleet == nil, let target = runner, !MachineDispatch.isExplicitLocal(target) {
            throw ValidationError("--runner requires --profile")
        }
        if fleet != nil {
            if runner != nil { throw ValidationError("--fleet cannot be combined with --runner") }
            if profile != nil {
                throw ValidationError(
                    "--fleet cannot be combined with --profile (set profile per entry in the fleet file)")
            }
            if !ports.isEmpty { throw ValidationError("--fleet cannot be combined with --port") }
            if failed { throw ValidationError("--fleet cannot be combined with --failed") }
            if reportDir != nil { throw ValidationError("--fleet cannot be combined with --report-dir") }
            if skipBuild { throw ValidationError("--fleet cannot be combined with --skip-build") }
        }
        if split, fleet == nil {
            throw ValidationError("--split requires --fleet")
        }
        if broadcast {
            // 黙って無視しない(fleet の子へは中継していない。ports 経路にはレーンの名が無い)
            if fleet != nil { throw ValidationError("--broadcast cannot be combined with --fleet") }
            if profile == nil { throw ValidationError("--broadcast requires --profile") }
        }
        if forceLock, let message = RemoteDispatchFlagPolicy.forceLockRejection(
            host: runner, fleet: fleet, profile: profile) {
            throw ValidationError(message)
        }
        if let message = RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock(
            forceLock: forceLock, waitLock: waitLock) {
            throw ValidationError(message)
        }
        if waitLock != nil, let message = RemoteDispatchFlagPolicy.waitLockRejection(
            host: runner, fleet: fleet, profile: profile) {
            throw ValidationError(message)
        }
    }

    func run() async throws {
        // `--set` は validate() で検証済み(未知キー・不正値は既に弾かれている)。
        // **デバイスに依存しない設定は `--profile` の有無に関わらず1つの経路で決まる**
        // (`DeviceIndependentRunSettings`)。`--profile` ありの経路は `ProfileResolver.resolve`
        // が同じ上書きをもう一度当てる(実プロファイルの値まで見えるので、ここでの計算は
        // その代わりにはならない ——ここは「プロファイルを経由しない env トグル」専用)。
        // BridgeClient(ホスト・サブプロセス両方)が FT_FAST_INPUT を読む
        let profileOverrides = try RunProfileSetOverride.parse(setOverrides)
        let noProfileSettings = DeviceIndependentRunSettings.resolve(
            DeviceIndependentRunSettings.profileLessBase.applyingOverrides(profileOverrides))
        RunEnvironment.apply(noProfileSettings)
        // リモート実行はここで打ち切る(以降はローカル実行の段取り。フラグはコマンドラインごと
        // リモートへ中継されるので、向こう側の fleetest が同じ env を自分で立てる)。
        // dry-run だけは送らない(--runner 明示・マシンプロファイルの host 自動のどちらも。
        // 理由と罠は RemoteDispatchGate の宣言。優先順位・食い違いは resolveEffectiveDispatchTarget
        // → FTCore.MachineDispatch に委譲。ユーザー決定: マシンプロファイルで
        // host を持たせることで、実行プロファイル経由で間接的にリモートを指定できるようにした)
        // デバイスが複数の機械にまたがる実行プロファイルは、ホストごとのサブ実行へ分ける
        // (単一ディスパッチでは「そのホストに無いデバイス」が解決できない)。--runner 明示や
        // 全台が同じ機械なら nil が返り、従来の経路をそのまま通る
        if !dryRun, fleet == nil, let profile,
           let groups = try DeviceMachineRunner.plan(
               project: try ScenarioHost.project(named: project), profileName: profile,
               explicitHost: runner, deviceFilter: devices, overrides: profileOverrides) {
            let exitCode = try await DeviceMachineRunner.run(
                project: try ScenarioHost.project(named: project), profileName: profile,
                groups: groups, scenarios: scenarios, folders: folders,
                setOverrides: profileOverrides, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                performanceMode: performanceMode, forceLock: forceLock, waitLock: waitLock,
                remoteDir: remoteDir, remoteTimeout: remoteTimeout,
                remoteArtifacts: remoteArtifacts, quiet: quiet, junit: junit,
                broadcast: broadcast)
            if exitCode != 0 { throw ExitCode(exitCode) }
            return
        }
        if !dryRun, let dispatch = try resolveEffectiveDispatchTarget(
        explicitTarget: runner, profile: profile, project: project,
            requireProfileMachine: true, warn: { ConsoleOut.out("⚠️ \($0)") },
            overrides: profileOverrides) {
            try await dispatchToRemoteHost(dispatch)
            return
        }
        // dry-run だけは送らない(--runner と同じ規律。RemoteDispatchGate の宣言参照)
        if let fleet, !dryRun {
            try await dispatchToFleet(fleet)
            return
        }
        PhaseLog.mark("start")
        let testProject = try ScenarioHost.project(named: project)
        PhaseLog.mark("project-resolved")

        // ビルドはホスト側で 1 回だけ(サブプロセスは自らビルドしない)
        if !skipBuild {
            ConsoleOut.out("→ Building scenarios (\(testProject.name))...")
            try ScenarioHost.build(project: testProject)
        }
        PhaseLog.mark("build")
        let all = try ScenarioHost.list(project: testProject)
        PhaseLog.mark("scenario-list")
        guard !all.isEmpty else {
            throw ValidationError(
                "no scenarios (add a @TestClass under TestProjects/\(testProject.name)/scenarios/)")
        }
        var selected = try ScenarioSelection.resolve(scenarios, from: all, scenariosDir: testProject.scenariosDir)
        if scenarios.isEmpty {
            let deletedCount = all.filter(\.deleted).count
            if deletedCount > 0 {
                ConsoleOut.out("→ Excluded \(deletedCount) deleted (@Deleted) scenario(s)")
            }
            // deleted 側と二重計上しないよう、deleted も付いているものは deleted のほうで数える
            let draftCount = all.filter { $0.draft && !$0.deleted }.count
            if draftCount > 0 {
                ConsoleOut.out("→ Excluded \(draftCount) draft (@Draft) scenario(s)")
            }
        }
        if !folders.isEmpty {
            selected = try Self.filterByFolders(selected, folders: folders,
                                                scenariosDir: testProject.scenariosDir)
        }
        if failed {
            let failedSet = LastResultsStore.failedIDs(project: testProject)
            selected = selected.filter { failedSet.contains($0.id) }
            guard !selected.isEmpty else {
                ConsoleOut.out("No scenarios failed last time (everything passed, or nothing has run)")
                return
            }
            ConsoleOut.out("→ Re-running the \(selected.count) scenario(s) that failed last time")
        }
        guard !selected.isEmpty else {
            ConsoleOut.out("Nothing to run (every scenario is marked @Deleted or @Draft)")
            return
        }
        // LPT 投入順の適用は実行経路ごとに行う(実効 platform が確定してからでないと
        // 別 platform の実績で並べてしまう): --profile は ProfileRunner.run、--port は runParallel。
        // 逐次実行は並列度が無いので並べ替えない
        let items = selected.map { ScenarioRunItem(info: $0) }

        // dry-run はデバイスにも FM にも触れないので、供給・接続・FM 診断・結果記録を全部飛ばす。
        // **RunRecorder を作らない**(実行していない結果を results DB と --failed の判断材料に
        // 混ぜないため。ScenarioHost も dryRun では LastResultsStore へ書かない)
        if dryRun {
            if profile != nil {
                ConsoleOut.out("ℹ️ --dry-run touches no device, so --profile is not used"
                      + " (--platform decides which ios { } / android { } blocks run)")
            }
            if runner != nil {
                ConsoleOut.out("ℹ️ --dry-run touches no device, so --runner is not used"
                      + " (the scenarios are validated locally, from the same source the remote would run)")
            }
            if fleet != nil {
                ConsoleOut.out("ℹ️ --dry-run touches no device, so --fleet is not used"
                      + " (the scenarios are validated locally, from the same source every fleet entry would run)")
            }
            if !profileOverrides.isEmpty {
                ConsoleOut.out("ℹ️ --dry-run touches no device, so --set is not used"
                      + " (dry-run always runs with FM disabled)")
            }
            let failedCount = await runDryRun(items, project: testProject)
            ConsoleOut.out(failedCount == 0
                  ? "✅ All \(items.count) scenario(s) passed the dry-run"
                  : "❌ \(failedCount) of \(items.count) scenario(s) failed the dry-run")
            if failedCount > 0 { throw ExitCode(1) }
            return
        }

        // **availability(FMDoctor.check)では判定しない** —— `.available` のまま実呼び出しが
        // 全滅する状態が実在する(2026-07-22 実測)。判定は --profile 経路と同じ1箇所へ委ねる。
        //
        // **--profile のときはここで撃たない**(2026-09-03 の実 run で二重に出た)。あちらは
        // `ProfileRunner.run` が**プロファイルの実効トグル**で撃つので、ここで撃つと同じ警告が
        // 2行並ぶうえ、機能ごとのトグルを持たないこちらの既定のほうが情報として粗い。
        // プロファイル無しの run にはその呼び出し元が無いので、ここが唯一の口になる
        // (`--set` がデバイス一覧・録画基盤に依存するキーを持つかは validate() が既に検査済み)
        if profile == nil {
            await ProfileRunner.warnIfFMDegraded(fm: noProfileSettings.fm) { ConsoleOut.out($0) }
        }

        PhaseLog.mark("fm-doctor")
        let recorder = RunRecorder.begin(project: testProject, profile: profile, trigger: "cli",
                                         runGroup: runGroup)
        PhaseLog.mark("recorder-begin")

        if let profile {
            // 明示 --runner local はこの機械で走らせる指定なので、ホスト混在プロファイルでは
            // local 枠だけに絞る(他ホスト担当分まで手元で解決すると存在しない台を掴む。
            // マシン別サブ実行は --device/--device-machine を持つのでこの分岐に入らない)。
            // **明示 --device があっても絞る** —— 名前だけでは同名の台が別の機械にもあるとき
            // そちらのエントリに解決し、向こうの UDID を手元で探して
            // "no simulator with that UDID" で止まる(受け手報告 2026-08-24)。判定は
            // --runner <リモート> と同じ machineScopedDeviceFilter(RemoteDispatchExplicitDeviceScope)
            var effectiveDeviceFilter = devices
            var effectiveDeviceHost = deviceMachine
            if deviceMachine == nil, MachineDispatch.isExplicitLocal(runner) {
                (effectiveDeviceFilter, effectiveDeviceHost) = try machineScopedDeviceFilter(
                    project: testProject, profile: profile,
                    targetMachine: DeviceMachineGrouping.localDisplayName, requestedDevices: devices,
                    overrides: profileOverrides)
            }
            let (runSummary, fmSettings) = try await ProfileRunner.run(
                project: testProject, profileName: profile, items: items,
                setOverrides: profileOverrides,
                reportDirOverride: reportDir,
                quiet: quiet, lpt: !noLPT,
                lptHistoryRuns: lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns,
                performanceMode: performanceMode,
                deviceFilter: effectiveDeviceFilter,
                deviceMachine: effectiveDeviceHost,
                workspaceOverride: workspace,
                recorder: recorder,
                broadcast: broadcast)
            let failedCount = runSummary.failed
            // **回した本数は items.count ではない** —— ProfileRunner が OS 対象外
            // (`@TestClass(platform:)` / `@Test(platform:)`)を投入前に外すので、
            // ここで items.count を使うと「12本全部成功」と出しつつ10本しか走っていない、になる
            let ranCount = runSummary.total
            // --broadcast の total は (本数 × 台数) なので items.count との差は対象外の数にならない
            // (対象外の件数は ProfileRunner が「Skipped N scenario(s) …」で出している)
            let notApplicable = broadcast ? 0 : items.count - ranCount
            PhaseLog.mark("profile-run-done")
            recorder.finish(total: ranCount, passed: ranCount - failedCount, failed: failedCount,
                            degradedWorkers: runSummary.degradedWorkers,
                            freezeRetries: runSummary.freezeRetries,
                            blankRepairs: runSummary.blankRepairs,
                            blankExclusions: runSummary.blankExclusions,
                            measurementInvalid: runSummary.measurementInvalid,
                            measurementInvalidReasons: runSummary.measurementInvalidReasons,
                            workerAnomalies: runSummary.workerAnomalies,
                            performanceMode: runSummary.performanceMode,
                            fmSettings: fmSettings)
            PhaseLog.mark("recorder-finish")
            try writeJUnitIfRequested(project: testProject, recorder: recorder)
            let skippedSuffix = notApplicable > 0
                ? " (\(notApplicable) skipped: declared for another platform)" : ""
            // --broadcast は (シナリオ × デバイス) を数える。単位を言わないと「3本のはずが
            // 24 passed」に見える
            let unit = broadcast ? "scenario run(s) (one per scenario per device)" : "scenario(s)"
            ConsoleOut.out(failedCount == 0
                  ? "✅ All \(ranCount) \(unit) passed\(skippedSuffix)"
                  : "❌ \(failedCount) of \(ranCount) \(unit) failed\(skippedSuffix)")
            // **合否は変えず、劣化だけ伝える**。FM が死んでいると occlusion-guard・
            // 自己修復・screenLooksLike が黙って素通りするので、緑は「守りが効いた緑」ではない。
            // 赤のときも、切り分けの出発点として先に知りたい情報(自分の変更か FM か)
            //
            // 2つ出すのは根拠が別だから: 台帳(FMLiveness)は**この機械の FM の生死**で、
            // 呼び出しが0件でも言える。fmUnavailableScenarios は**実際に FM を引いて全滅した
            // シナリオ数**。前者だけだと「死んでいたが今回の run は FM を引かなかった」が
            // 同じ文になり、後者だけだと**ブレーカが落ちて1回も呼ばずに素通りした run で沈黙する**
            let fmReading = FMLiveness.current()
            if let reason = fmReading.deadSummary() {
                ConsoleOut.out("⚠️ FM is dead on this machine (\(fmReading.deadPaths.joined(separator: " + "))):"
                    + " a green here is not a guarded green — the occlusion-guard, self-healing and"
                    + " screenLooksLike passed through silently."
                    + "\n   \(reason)")
            }
            if runSummary.fmUnavailableScenarios > 0 {
                ConsoleOut.out("⚠️ FM unavailable: \(runSummary.fmUnavailableScenarios) scenario(s) ran"
                    + " with occlusion-guard / self-healing / screenLooksLike silently disabled."
                    + " Read this run's result with that in mind"
                    + " (confirm with: fleetest doctor --fm-only)")
            }
            if failedCount > 0 { throw ExitCode(1) }
            return
        }

        // `--report-dir` が優先(validate() が両方指定を既にエラーにしている)。次点は
        // `--set reportDir=`。`defaultTimeout`/`scenarioTimeout` はこの経路(RunScenarios)に
        // 専用フラグが無いため `--set` だけが口
        let reportDirPath = reportDir ?? noProfileSettings.reportDir ?? testProject.reportsDir.path
        // --set record=true の可否(単一接続では録画セッションが無い)は validate() が既に検査済み
        let iosPorts: [UInt16] = ports.isEmpty ? [BridgeAPI.defaultPort] : ports

        // record:true のときだけ VideoRecordingConfig を注入(--profile 経路と同じ形。
        // bitrate は --set recordBitrateKbps=... で上書きできる(既定は
        // VideoRecordingConfig.defaultBitrateKbps。effectiveRecordBitrateKbps が0以下を弾く)
        let recordingConfig: VideoRecordingConfig? = noProfileSettings.record
            ? VideoRecordingConfig(runDir: recorder.runDir, androidADBPath: try? AndroidDriver.findADB(),
                                   failuresOnly: noProfileSettings.recordFailuresOnly,
                                   bitrateKbps: RunProfileDocument.effectiveRecordBitrateKbps(
                                       noProfileSettings.recordBitrateKbps),
                                   fullResolution: noProfileSettings.recordFullResolution)
            : nil

        let failedCount: Int
        if iosPorts.count <= 1 {
            failedCount = try await runSequential(items, project: testProject,
                                                  port: iosPorts[0], reportDir: reportDirPath,
                                                  settings: ScenarioExecutionSettings(noProfileSettings),
                                                  homeOnStart: noProfileSettings.homeOnStart,
                                                  recorder: recorder)
        } else {
            failedCount = await runParallel(items, project: testProject,
                                            iosPorts: iosPorts, reportDir: reportDirPath,
                                            settings: ScenarioExecutionSettings(noProfileSettings),
                                            homeOnStart: noProfileSettings.homeOnStart,
                                            recordingConfig: recordingConfig,
                                            recorder: recorder)
        }
        // --profile 無しの経路(runSequential/runParallel)は `--set` の上書きを当てた既定
        // ドキュメントの実効値(noProfileSettings)をそのまま使う(--profile 経路と同じ
        // DeviceIndependentRunSettings を通す。ProfileResolver.resolve の宣言参照)
        recorder.finish(total: items.count, passed: items.count - failedCount, failed: failedCount,
                        // --performance は --profile 専用(ヘルプ参照)。この経路は素通りするので false
                        performanceMode: false,
                        fmSettings: FMSettingsRecord(
                            fm: noProfileSettings.fm.enabled, heal: noProfileSettings.fm.heal,
                            falsePositiveCheck: noProfileSettings.fm.falsePositiveCheck,
                            screenLooksLike: noProfileSettings.fm.screenLooksLike,
                            triage: noProfileSettings.fm.triage,
                            ocr: noProfileSettings.ocr,
                            ocrFalsePositiveCheck: noProfileSettings.ocrFalsePositiveCheck))
        try writeJUnitIfRequested(project: testProject, recorder: recorder)

        ConsoleOut.out(failedCount == 0
              ? "✅ All \(items.count) scenario(s) passed"
              : "❌ \(failedCount) of \(items.count) scenario(s) failed")
        if failedCount > 0 {
            throw ExitCode(1)
        }
    }

    /// `--runner` または(自動)マシンプロファイルの `host`: ローカルビルド・実行をせず、対等ピア
    /// (SSH 到達可能な foundation-tester clone)に丸ごとディスパッチする
    /// (docs/remote-runner.md §3・§7・Phase 1)。デバイス割当競合を避けるためリモート1本での
    /// 実行のみサポートし、ローカル専用オプションは併用不可にする
    private func dispatchToRemoteHost(_ dispatch: EffectiveDispatchTarget) async throws {
        guard let profile else {
            throw ValidationError("--runner requires --profile")
        }
        // machineScopedDeviceFilter と dispatcher.dispatch の両方が同じ上書きを見る必要がある
        // (欠陥②。片方だけに通すと別マシンのデバイスを解決しつつ元マシンへ中継する)
        let dispatchOverrides = try RunProfileSetOverride.parse(setOverrides)
        // 拒否 or 注記の分岐は FTRemote.RemoteDispatchFlagPolicy に委譲(欠陥1)。origin が
        // 自動ディスパッチ(マシンプロファイルの host)なら --skip-build は注記のみで無視する
        // (リモートは常に自前でビルドする)。他の3つは自動でも意味を持たせられないため拒否のまま
        let origin = dispatch.origin
        if !ports.isEmpty {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--port", origin: origin))
        }
        if reportDir != nil {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--report-dir", origin: origin))
        }
        if failed {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--failed", origin: origin))
        }
        if skipBuild {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.skipBuild(origin: origin))
        }

        let resolved = try resolveRemoteTarget(dispatch, remoteDirOverride: remoteDir)
        resolved.announce()
        let artifactsMode = try RemoteArtifactsMode.parse(remoteArtifacts)
        let testProject = try ScenarioHost.project(named: project)
        let localRoot = try RepoRoot.find()
        let dispatcher = RemoteRunDispatcher(
            host: resolved.hostSpec, remoteDirRaw: resolved.remoteDirRaw, localRepoRoot: localRoot,
            artifacts: artifactsMode, forceLock: forceLock, waitLock: waitLock, hostLabel: dispatch.rawTarget)
        var scopedDevices = devices
        var scopedDeviceHost = deviceMachine
        if deviceMachine == nil {
            (scopedDevices, scopedDeviceHost) = try machineScopedDeviceFilter(
                project: testProject, profile: profile, targetMachine: dispatch.rawTarget,
                requestedDevices: devices, overrides: dispatchOverrides)
        }
        let exitCode = try await dispatcher.dispatch(
            project: testProject, profile: profile, scenarios: scenarios, folders: folders,
            deviceNames: scopedDevices, deviceMachine: scopedDeviceHost,
            setOverrides: dispatchOverrides,
            noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            performanceMode: performanceMode, broadcast: broadcast,
            localJUnitPath: junit, remoteTimeoutSeconds: remoteTimeout, runGroup: runGroup)
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    /// RemoteDispatchFlagPolicy.Decision の適用。注記は ConsoleOut 経由(print を使わない —
    /// RemoteRunDispatcher.log と同じ規律。stdout が端末でないと libc の行バッファが効かず
    /// 出力が遅延・欠落しうる。他の書き手とロックを共有するのでここだけ直書きにしない)
    private func applyFlagPolicy(_ decision: RemoteDispatchFlagPolicy.Decision) throws {
        switch decision {
        case .allowed:
            return
        case .ignoredWithNote(let note):
            ConsoleOut.out(note)
        case .rejected(let message):
            throw ValidationError(message)
        }
    }

    /// `--fleet`: profiles/fleets/<name>.json の全エントリを並行実行する(docs/remote-runner.md
    /// §13)。検証は投入前に全部済ませる(FleetProfile.validate)。実体は FleetRunner
    /// (エントリごとに子プロセスを起動し、出力を host 名で前置する)
    private func dispatchToFleet(_ fleetName: String) async throws {
        let testProject = try ScenarioHost.project(named: project)
        let doc = try FleetProfile.load(project: testProject, name: fleetName)
        let registeredNames = Set((LocalConfig.load().remoteHosts ?? []).map(\.machine))
        let issues = FleetProfile.validate(doc, project: testProject, registeredHostNames: registeredNames)
        guard issues.isEmpty else {
            throw ValidationError((["fleet \"\(fleetName)\" is invalid:"] + issues.map { "  - \($0)" })
                .joined(separator: "\n"))
        }
        let exitCode = try await FleetRunner.run(
            project: testProject, fleetName: fleetName, fleet: doc,
            scenarios: scenarios, folders: folders,
            setOverrides: try RunProfileSetOverride.parse(setOverrides),
            noLPT: noLPT, lptHistoryRuns: lptHistoryRuns, performanceMode: performanceMode,
            forceLock: forceLock, waitLock: waitLock, remoteDir: remoteDir, remoteTimeout: remoteTimeout,
            remoteArtifacts: remoteArtifacts, split: split, quiet: quiet, junit: junit)
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    /// --junit: run の記録(runDir/scenarios/*.json)から JUnit XML を書き出す。
    /// **ExitCode(1) を投げる前に呼ぶ**(失敗 run こそ CI がレポートを要る)。
    /// 書き込み失敗は run の成否を変えない(warn のみ。CI 側はファイル欠如で気付ける)
    private func writeJUnitIfRequested(project: TestProject, recorder: RunRecorder) throws {
        guard let junit else { return }
        let records = RunResultsStore.records(runDir: recorder.runDir)
        let xml = JUnitReportWriter.xml(project: project.name, records: records)
        let url = URL(fileURLWithPath: junit)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: url, atomically: true, encoding: .utf8)
            ConsoleOut.out("📄 JUnit report: \(junit) (\(records.count) testcase(s))")
        } catch {
            ConsoleOut.out("⚠️ Failed to write the JUnit report: \(junit) (\(error.localizedDescription))")
        }
    }

    /// --folder でシナリオを絞り込む(クラス名→ソースファイル→フォルダ名で照合)。
    /// 絞り込んだ結果が空、かつ未知のフォルダ名が含まれる場合はエラー
    static func filterByFolders(_ infos: [ScenarioInfo], folders: [String],
                                scenariosDir: URL) throws -> [ScenarioInfo] {
        let classFile = ScenarioFolders.classFileMap(scenariosDir: scenariosDir)
        let filtered = ScenarioFolders.filter(infos, byFolders: folders) { className in
            classFile[className].flatMap { ScenarioFolders.folderName(of: $0, scenariosDir: scenariosDir) }
        }
        if filtered.isEmpty {
            let available = ScenarioFolders.list(scenariosDir: scenariosDir)
            let unknown = folders.filter { !available.contains($0) }
            if !unknown.isEmpty {
                throw ValidationError(
                    "folder not found: \(unknown.joined(separator: ", "))"
                    + " (available: \(available.joined(separator: ", ")))")
            }
        }
        return filtered
    }

    /// ブリッジの /status(デバイス名)→ 起動中シミュレータの一意な同名から UDID を解決する。
    /// launch 事前検査(LaunchPreflightDriver)と FastLaunch 用。
    /// **プロファイル経路は provision の udid を渡すのでここを通らない** —— これは
    /// `--port` 直指定の経路だけの相関。
    ///
    /// 同名複数・未起動・応答なしは nil(検査なしで従来動作)だが、**黙って落とさない**:
    /// 事前検査が外れると、未インストールのまま launch して XCUITest ランナーが死ぬ経路
    /// (LaunchPreflightDriver のコメント)がそのまま開く。Xcode はランタイムごとに同名の
    /// シミュレータを作るので、同名2台は受け手環境で普通に起きる(2026-08-06 に実例)
    private static func resolveUdid(port: UInt16) async -> String? {
        guard let status = try? await PortDirectIOSTarget(port: port).makeDriver(timeoutSeconds: 5).status(),
              let catalog = try? SimulatorCatalog.devices() else { return nil }
        let matches = catalog.filter { $0.booted && $0.name == status.device }
        if matches.count == 1 { return matches[0].udid }
        ConsoleOut.err(
            "install preflight and fast launch are disabled:"
             + " \(matches.count) booted simulators are named \"\(status.device)\"."
             + " Launching an app that is not installed will kill the XCUITest runner."
             + " Use a run profile (--profile) to target a simulator by UDID.")
        return nil
    }

    // MARK: - 逐次実行(ライブ出力)

    /// dry-run(No-Load-Run): デバイスにも FM にも触れずステップを列挙・検証する。
    /// **レポートは一時ディレクトリへ書かせて捨てる** —— ランナーは dry-run でもレポートを書くので、
    /// 実行していない結果を reports/ に残すと results の集計と紛れる(`ScenarioHost.dryRunSteps`・
    /// MCP の `ft_dry_run` と同じ扱い。案内すると開けないパスを渡すことになるので report 行も落とす)。
    /// 接続情報は NullDriver 固定のため使われず、**platform だけが `ios { }` / `android { }` の
    /// 分岐と `#id` 台帳の照合に効く**。整形は MCP・サブプロセスと同じ `ScenarioLogFormatter`
    /// `--app-id` は platform 別に書き分けられないので両 platform に同じ値を配る
    /// (書き分けが要るなら実行プロファイルを使う)。nil なら空 = 子が明示エラーを出す
    static func appBundleIDs(_ app: String?) -> [String: String] {
        guard let app else { return [:] }
        return ["ios": app, "android": app]
    }

    private func runDryRun(_ items: [ScenarioRunItem], project: TestProject) async -> Int {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var failedCount = 0
        for item in items {
            let platform = item.info.platform ?? resolvedPlatform
            // quiet: runSequential と同じ扱い(成功なら結果1行・失敗ならバッファ全体)
            var buffer: [String] = []
            let passed = await ScenarioHost.run(
                project: project, scenarioID: item.info.id,
                connection: DriverConnection(platform: platform),
                // **`enabled: false`(= 子へ --no-fm)**。heal だけ切ると失敗のたびに triage が
                // 走り、デバイスも画面も無いのに FM の直列化待ちを払う(数秒。実測で確認)
                settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false, heal: false)),
                reportDir: tempDir.path,
                dryRun: true, appBundleID: appID) { event in
                let lines = ScenarioLogFormatter.lines(for: event)
                    .filter { !$0.contains("→ report:") }
                if quiet {
                    buffer.append(contentsOf: lines)
                } else {
                    for line in lines { ConsoleOut.out(line) }
                }
            }
            if quiet {
                ConsoleOut.out(passed ? "✅ \(item.info.id)" : "❌ \(item.info.id)")
                if !passed { ConsoleOut.out(buffer.joined(separator: "\n")) }
            }
            if !passed { failedCount += 1 }
        }
        return failedCount
    }

    private func runSequential(_ items: [ScenarioRunItem], project: TestProject,
                               port: UInt16, reportDir: String,
                               settings: ScenarioExecutionSettings,
                               homeOnStart: Bool,
                               recorder: RunRecorder?) async throws -> Int {
        let iosUdid = await Self.resolveUdid(port: port)
        // homeOnStart は「run 開始時に1回」の予防措置(ProfileWorkerFactory.pressHomeOnStart)。
        // この経路は毎シナリオでワーカーを組み直すので、実際に使う platform 分の使い捨てワーカーを
        // ループの前で1回だけ組んで渡す(ループ側の実行用インスタンスとは別物)
        let platformsInUse = Set(items.map { $0.info.platform ?? resolvedPlatform })
        var primingWorkers: [RunWorker] = []
        if platformsInUse.contains("ios") {
            // 宛先・token・実機判定は記録から(PortDirectIOSTarget)。**子プロセスへも同じ宛先を
            // 渡す**(DriverConnection.host → `--bridge-host`)。片方だけだと親は繋がるのに
            // 子だけ接続拒否になる
            primingWorkers.append(
                PortDirectIOSTarget(port: port).makeWorker(label: "ios", simulatorUDID: iosUdid))
        }
        if platformsInUse.contains("android"), let driver = try? AndroidDriver(serial: serial) {
            primingWorkers.append(RunWorker(
                label: "android", platform: "android", driver: driver,
                connection: DriverConnection(platform: "android", serial: serial)))
        }
        await ProfileWorkerFactory.prepareDevicesOnStart(
            primingWorkers, homeOnStart: homeOnStart) { ConsoleOut.out($0) }

        var failedCount = 0
        for item in items {
            let platform = item.info.platform ?? resolvedPlatform
            let driver: AppDriver
            let connection: DriverConnection
            if platform == "android" {
                driver = try AndroidDriver(serial: serial)
                connection = DriverConnection(platform: "android", serial: serial)
            } else {
                let target = PortDirectIOSTarget(port: port)
                driver = target.makeDriver()
                connection = target.connection(simulatorUDID: iosUdid)
            }
            _ = try await driver.status()
            let worker = RunWorker(label: platform, platform: platform,
                                   driver: driver, connection: connection)
            // quiet: 全行をバッファし、成功なら結果1行のみ・失敗ならバッファ全体(失敗詳細)を出す
            var buffer: [String] = []
            let outcome = await ScenarioRunner.runOne(
                project: project, item: item, worker: worker, settings: settings,
                reportDir: URL(fileURLWithPath: reportDir),
                recorder: recorder,
                appBundleID: appID) { event in
                let lines = RunLogFormatter.lines(for: event)
                if quiet {
                    buffer.append(contentsOf: lines)
                } else {
                    for line in lines { ConsoleOut.out(line) }
                }
            }
            if quiet {
                if outcome == .passed {
                    ConsoleOut.out("✅ \(item.info.id)")
                } else {
                    ConsoleOut.out("❌ \(item.info.id)")
                    ConsoleOut.out(buffer.joined(separator: "\n"))
                }
            }
            if outcome != .passed { failedCount += 1 }
        }
        return failedCount
    }

    // MARK: - 並列実行(iOS はポート毎のワーカー、Android は専用ワーカー)

    private func runParallel(_ rawItems: [ScenarioRunItem], project: TestProject,
                             iosPorts: [UInt16], reportDir: String,
                             settings: ScenarioExecutionSettings,
                             homeOnStart: Bool,
                             recordingConfig: VideoRecordingConfig?,
                             recorder: RunRecorder?) async -> Int {
        let defaultPlatform = resolvedPlatform
        let items = LPTOrdering.apply(rawItems, project: project, defaultPlatform: defaultPlatform,
                                      enabled: !noLPT,
                                      historyRuns: lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns,
                                      log: { ConsoleOut.out($0) })
        let androidItems = items.filter { ($0.info.platform ?? defaultPlatform) == "android" }
        let portList = iosPorts.map(String.init).joined(separator: ", ")
        ConsoleOut.out("🚀 Parallel run: \(iosPorts.count) iOS worker(s) (port: \(portList))"
              + (androidItems.isEmpty ? "" : " + 1 Android worker") + "\n")

        var workers: [RunWorker] = []
        for port in iosPorts {
            let udid = await Self.resolveUdid(port: port)
            workers.append(PortDirectIOSTarget(port: port).makeWorker(label: "ios:\(port)",
                                                                      simulatorUDID: udid))
        }
        if !androidItems.isEmpty {
            if let driver = try? AndroidDriver(serial: serial) {
                workers.append(RunWorker(label: "android", platform: "android", driver: driver,
                                         connection: DriverConnection(platform: "android",
                                                                      serial: serial)))
            } else {
                ConsoleOut.out("❌ Cannot initialise the Android driver (adb not found)")
                // ワーカー不在の android シナリオは orchestrator が flowSkipped(失敗扱い)にする
            }
        }

        // 一斉 launch 直後の黒画面を作らないための予防(ProfileRunner.run と同じ呼び出し)
        await ProfileWorkerFactory.prepareDevicesOnStart(
            workers, homeOnStart: homeOnStart) { ConsoleOut.out($0) }

        let orchestrator = RunOrchestrator(project: project, workers: workers,
                                           settings: settings,
                                           reportDir: URL(fileURLWithPath: reportDir),
                                           recorder: recorder,
                                           recordingConfig: recordingConfig,
                                           appBundleIDs: Self.appBundleIDs(appID))
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        // シナリオ毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)。
        // quiet: 成功シナリオは結果1行のみ・失敗シナリオはバッファ全体(失敗詳細)を出す
        var buffers: [URL: [String]] = [:]
        var names: [URL: String] = [:]
        for await event in orchestrator.events {
            let lines = RunLogFormatter.lines(for: event)
            switch event {
            case .flowStarted(_, let url, let flowName, _):
                names[url] = flowName
                buffers[url, default: []].append(contentsOf: lines)
            case .step(_, let url, _), .flowHealed(_, let url):
                buffers[url, default: []].append(contentsOf: lines)
            case .flowFinished(_, let url, let passed, _, _, _):
                let all = (buffers.removeValue(forKey: url) ?? []) + lines
                if quiet {
                    ConsoleOut.out(passed ? "✅ \(names[url] ?? url.lastPathComponent)"
                                 : "❌ \(names[url] ?? url.lastPathComponent)\n" + all.joined(separator: "\n"))
                } else {
                    ConsoleOut.out(all.joined(separator: "\n"))
                }
            default:
                if !lines.isEmpty { ConsoleOut.out(lines.joined(separator: "\n")) }
            }
        }
        return await summary.failed
    }
}

