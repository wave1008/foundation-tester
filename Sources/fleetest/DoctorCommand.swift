// DoctorCommand.swift
// fleetest doctor: FM/Xcode/シミュレータ/ブリッジの事前診断コマンド

import ArgumentParser
import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import FTDSL

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
        abstract: "Preflight checks for Foundation Models, Xcode and simulators",
        discussion: "Without --fm-only/--roots-only it also stops bridges that are certainly stale:"
            + " an older version started from this repository, or one whose owning repository no longer"
            + " exists. Bridges owned by another workspace, or whose owner is unknown, are only reported.")

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
        // run() は --roots-only を先に見て抜けるので、併用すると --fm-only が黙って効かない
        if fmOnly, rootsOnly { throw ValidationError("--fm-only cannot be combined with --roots-only") }
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

        // **❌ を出したら非0で終わる**(`--fm-only` / `--roots-only` と同じ向き)。
        // 全体レポートだけ常に 0 を返していたので、exit code で門を作る呼び手
        // (スキル・CI)は赤い行を見落とした。⚠️(警告)は数えない
        var problems = 0
        if !fm.available { problems += 1 }
        if !vision.available, !visionUnsupported { problems += 1 }

        if !printRoots() { problems += 1 }

        let xcode = try Shell.run(["xcodebuild", "-version"])
        let xcodeLine = xcode.output.split(separator: "\n").first.map(String.init) ?? "unknown"
        ConsoleOut.out(xcode.status == 0 ? "✅ \(xcodeLine)" : "❌ xcodebuild not found")
        if xcode.status != 0 { problems += 1 }

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
        if xcodegen.status != 0 { problems += 1 }

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
                problems += 1
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

        // 何が赤かったかは上の行がそのまま持っているので、ここでは数だけ添えて非0で抜ける
        if problems > 0 {
            ConsoleOut.out("❌ \(problems) check(s) failed — see the ❌ lines above")
            throw ExitCode(1)
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
        // 応答しなかったポート。**「答えない = 何も居ない」ではない** —— ブリッジが死んで
        // 転送役(実機なら iproxy)だけがポートを握っている形は /status に答えないので、
        // この走査からは丸ごと消えて「異常なし」と報告されていた(実地 2026-09-23 の負荷テスト:
        // 画面ロックで死んだ実機のトンネルが採番範囲のポートを握ったまま、doctor は緑だった)
        var silentPorts: [UInt16] = []
        for port in BridgeAPI.defaultPort...(BridgeAPI.defaultPort + 31) {
            guard let status = BridgeLauncher.probeForeignBridge(port: port, timeout: 0.4)
            else { silentPorts.append(port); continue }
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
        // **残っているのがトンネルだけのポート**を足す。判定は**プロセスの実体**で行う ——
        // 応答の速さ(`probeStatus`)で決めると、駆動中で /status に答えないだけの in-app
        // ブリッジまで「固まり」として並べてしまう(実測: run 中に 8 ポートが誤って並んだ)
        // **待受を先に見る**(非ブロッキング connect)—— 占有者の照合は lsof + ps で1ポート
        // あたり約 0.2 秒。誰も待受していないポートにトンネルは居ないので、ここで落とす。
        // **宛先はループバック固定**(`repoRoot: nil`)= iproxy が張るのはそこだけ
        for port in silentPorts where BridgeDiscovery.isBound(port: port, repoRoot: nil)
            && PortHolder.isHeldByTunnelOnly(port: port) {
            findings.append("   - port \(port) — only a USB tunnel (iproxy) is holding this port;"
                + " its bridge is gone (a dead runner leaves this behind, and the port then looks"
                + " occupied to everything else). Run `fleetest bridge down --port \(port)`")
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
