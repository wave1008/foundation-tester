// RemoteMonitorFanout.swift
// **リモート機のデバイスの状態と画面を、手元のモニターへ合流させる**(docs/remote-runner.md §13)。
//
// 手元の `fleetest api monitor` は simctl/adb を叩くので**この機械のデバイスしか観測できない**。
// 別の機械のデバイスは、その機械で `api monitor --device-host <host>` を1本走らせ、その
// NDJSON を親が取り込む。親がやることは3つだけ:
//   - `monitorDevices` は**保持する**(親が毎サイクル出す devices 配列へ、マシンプロファイルの
//     並び順のまま差し込む。子と親でサイクルが揃っていないので、そのまま素通しはできない)
//   - `monitorFrame` / `monitorError` は**行のまま中継する**(device id にホストが入っているので
//     受け手[拡張]はそのままタイルを特定できる。作り直すと base64 を1往復ぶん無駄に触る)
//   - stdin の制御行(pause/resume/suppressFrames)は**全子へ素通しする**(id の集合で判定する
//     だけなので、自分の持たない id が混ざっていても害はない)
//
// **子は必ず `remote exec` 経由**(ssh の張り方・PATH 補正・ホスト解決を委ねる。専用の ssh 経路を
// 新設しない = docs/remote-runner.md §14)。**先にプロジェクトを rsync する**(RemoteProjectSync)。
//
// 子が落ちたら、そのホストのデバイスは**「状態を取得できない」に戻す**(古い状態を出し続けない ——
// 向こうが落ちているのに connected と言い続けるのが最悪)。再接続は指数的に間隔を空けて試み、
// 短時間での失敗が続いたら諦める(旧バイナリに `--device-host` が無い機械で無限に ssh を張らない)。

import FTCore
import Foundation

final class RemoteMonitorFanout: @unchecked Sendable {

    /// 起動直後の失敗が何秒未満なら「すぐ死んだ」とみなすか(ssh の接続確立 + fleetest の起動で
    /// 数秒はかかるので、それを超えて生きていたなら設定は通っていたと判断する)
    private static let quickFailureSeconds: TimeInterval = 15
    /// すぐ死ぬのが何回続いたら諦めるか(旧バイナリ・未セットアップの機械で無限に張り直さない)
    private static let quickFailureLimit = 3
    /// 再接続の待ち(秒)。回数に応じて伸ばす
    private static let retryDelaysSeconds: [UInt32] = [2, 5, 15]

    private let hosts: [String]
    private let project: String
    private let profile: String?
    private let interval: Double
    private let maxWidth: Int
    private let log: @Sendable (String) -> Void
    private let relayLine: @Sendable (String) -> Void

    private let lock = NSLock()
    /// ホストごとの最新の devices(id → 1台分)。子が落ちたら**そのホストのぶんを捨てる**
    private var devicesByHost: [String: [String: ApiMonitorDeviceInfo]] = [:]
    private var children: [String: Process] = [:]
    private var stopping = false

    init(hosts: [String], project: String, profile: String?, interval: Double, maxWidth: Int,
         log: @escaping @Sendable (String) -> Void,
         relayLine: @escaping @Sendable (String) -> Void) {
        self.hosts = hosts
        self.project = project
        self.profile = profile
        self.interval = interval
        self.maxWidth = maxWidth
        self.log = log
        self.relayLine = relayLine
    }

    /// ホストごとに1本ずつ、監視スレッドを立てる(スレッドの中で rsync → spawn → 再接続まで回す)
    func start() {
        for host in hosts {
            let thread = Thread { [weak self] in self?.superviseHost(host) }
            thread.name = "fleetest-monitor-fanout-\(host)"
            thread.start()
        }
    }

    /// いま把握しているリモートのデバイス(id → 1台分)。**子から一度も届いていないホストは
    /// 含まれない** —— 呼び出し側は欠けている台を「状態を取得できない」として出す
    func snapshot() -> [String: ApiMonitorDeviceInfo] {
        lock.lock(); defer { lock.unlock() }
        var merged: [String: ApiMonitorDeviceInfo] = [:]
        for (_, devices) in devicesByHost {
            merged.merge(devices) { current, _ in current }
        }
        return merged
    }

    /// stdin の制御行を全子へ素通しする(親が解釈した後に呼ぶ)
    func forwardControl(line: String) {
        lock.lock()
        let targets = Array(children.values)
        lock.unlock()
        for process in targets {
            guard let pipe = process.standardInput as? Pipe else { continue }
            // 相手が先に死んでいると EPIPE で例外が飛ぶ。1台の死で親を落とさない
            try? pipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        let targets = Array(children.values)
        children.removeAll()
        lock.unlock()
        for process in targets where process.isRunning {
            process.terminate()
        }
    }

    // MARK: - 1ホスト分の監督

    private func superviseHost(_ host: String) {
        if let failure = RemoteProjectSync.run(project: project, host: host) {
            log("[monitor] ❌ \(failure) — devices on \(host) stay unobserved")
            return
        }
        var quickFailures = 0
        while !isStopping() {
            let startedAt = Date()
            runChild(host: host)
            // 子が落ちた: そのホストの状態は**もう根拠が無い**ので捨てる
            lock.lock()
            devicesByHost.removeValue(forKey: host)
            children.removeValue(forKey: host)
            lock.unlock()
            if isStopping() { return }
            if Date().timeIntervalSince(startedAt) < Self.quickFailureSeconds {
                quickFailures += 1
            } else {
                quickFailures = 0
            }
            guard quickFailures < Self.quickFailureLimit else {
                log("[monitor] Giving up on \(host): the remote monitor died \(quickFailures) times right"
                    + " after starting (is its fleetest up to date? `fleetest remote setup \(host)`)."
                    + " Its devices stay unobserved until the monitor is restarted")
                return
            }
            let delay = Self.retryDelaysSeconds[min(quickFailures, Self.retryDelaysSeconds.count - 1)]
            log("[monitor] Reconnecting to \(host) in \(delay)s")
            sleep(delay)
        }
    }

    /// 子プロセス1本を最後まで回す(戻ったら子は死んでいる)
    private func runChild(host: String) {
        var args = ["remote", "exec", host, "--", "api", "monitor",
                    "--project", project,
                    "--interval", String(interval),
                    "--max-width", String(maxWidth),
                    // エイリアスは渡さない(転送時に畳んである。FTCore.RunnerProfileView)
                    "--device-machine", DeviceHostGrouping.localDisplayName]
        if let profile { args += ["--profile", profile] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteProjectSync.selfBinaryPath())
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // 子は stdin の EOF を終了指示として扱う。親が死ねばパイプが閉じて向こうも畳まれる
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            log("[monitor] ❌ cannot start the monitor for \(host): \(error.localizedDescription)")
            return
        }
        lock.lock()
        children[host] = process
        lock.unlock()

        let stderrThread = Thread { [weak self] in
            Self.forEachLine(of: stderr) { line in self?.log("[\(host)] \(line)") }
        }
        stderrThread.name = "fleetest-monitor-fanout-err-\(host)"
        stderrThread.start()

        Self.forEachLine(of: stdout) { [weak self] line in self?.ingest(line: line, host: host) }
        process.waitUntilExit()
    }

    /// 子の stdout 1行。devices は保持し、それ以外(frame/error)は行のまま中継する
    private func ingest(line: String, host: String) {
        struct KindOnly: Decodable { let kind: String }
        guard let data = line.data(using: .utf8),
              let kind = (try? JSONDecoder().decode(KindOnly.self, from: data))?.kind
        else { return }
        guard kind == "monitorDevices" else {
            // monitorFrame / monitorError。行のまま中継して受け手に判断させる
            relayLine(line)
            return
        }
        guard let event = try? JSONDecoder().decode(ApiMonitorDevicesEvent.self, from: data) else {
            log("[monitor] \(host): cannot read the remote monitorDevices line")
            return
        }
        var byID: [String: ApiMonitorDeviceInfo] = [:]
        for device in event.devices { byID[device.id] = device }
        lock.lock()
        devicesByHost[host] = byID
        lock.unlock()
    }

    private func isStopping() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    /// パイプを行単位で読み切る(RemoteDeviceFanout.runChild と同じ規律。availableData は
    /// 空 Data で EOF を表す)
    private static func forEachLine(of pipe: Pipe, _ body: (String) -> Void) {
        var buffer = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty { body(line) }
            }
        }
    }
}
