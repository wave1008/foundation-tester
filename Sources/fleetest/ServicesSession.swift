// サービス(scripts/compose.yaml)の起動と片付けの本体(docs/remote-runner.md §17「順序と失敗の扱い」「片付けの保証」)。
// 解釈・検査・計画は FTServices の純粋関数・入力集めは ServicesFacts・削除は ServicesTeardown。ここは順序と I/O だけ。
//
// 不変条件:
// - 控えは最初の資源(ネットワーク)を作る前に書く。書けなければ開始しない
// - どの段で止まっても、そこまでに作った資源を片付けてから投げる(ロックを握ったまま `teardown` を直に呼ぶ。`down` は取り直すので使わない)
// - 資源の ID を控えへ書くのは作った直後。作る直前に名前だけ先に書く(作成と控えの更新の間で死んでも名前で回収できる)
// - 失敗の記録は事実だけ(フェーズ・終了状態・出力の末尾)。原因の分類は置かない

import Darwin
import FTCore
import FTRemote
import FTServices
import Foundation

/// 読み出しスレッドとの受け渡しだけを行う箱(ロックで直列化)。
private final class ServicesLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []

    func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: lines)
        lock.unlock()
    }

    func takePending() -> [String] {
        lock.lock()
        defer { pending.removeAll(); lock.unlock() }
        return pending
    }
}

extension RuntimeCLI {
    struct LongResult {
        let status: Int32
        /// 出力の末尾(最大 `tailLineLimit` 行)。
        let tail: [String]
    }

    /// 出力の末尾として持つ行数の上限(失敗の文言に添える分。全文は log に流れている)。
    static let tailLineLimit = 30

    /// 長い CLI(pull / build / load)。**中断を届け**(`registerChildProcess`)、**終了は終了通知で待ち**(`waitpid` を直接呼ばない)、
    /// 出力は行ごとに log へ流し、無音が `RunHookStall.silentWarningSeconds` を跨ぐたびに警告を1行出す。タイムアウトは置かない
    /// (取得・ビルドの妥当な上限をこちらが決める根拠が無い。止めるのは中断と人)。
    func runLong(_ args: [String], label: String, interrupt: RunInterruptState?,
                 stallThreshold: Double = RunHookStall.silentWarningSeconds,
                 log: (String) -> Void) -> LongResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv(args)
        process.standardInput = FileHandle.nullDevice  // 対話しない
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let waitExit = ProcessExitWait.prepareTimed(process)  // 契約: run() より前に設定
        do {
            try process.run()
        } catch {
            log("⚠️ services: could not start \(label): \(error.localizedDescription)")
            return LongResult(status: 127, tail: [error.localizedDescription])
        }
        let unregister = interrupt?.registerChildProcess(process)
        defer { unregister?() }

        let readHandle = pipe.fileHandleForReading
        let readDone = DispatchSemaphore(value: 0)
        let sink = ServicesLineSink()
        DispatchQueue.global(qos: .utility).async {
            let splitter = StreamLineSplitter()
            while true {
                // availableData は届いた分だけ返す。1回ごとに解放の区切り(自動解放の NSData が抜けないループで溜まる)
                let eof: Bool = autoreleasepool {
                    let chunk = readHandle.availableData
                    if chunk.isEmpty { return true }
                    sink.append(splitter.feed(chunk))
                    return false
                }
                if eof { break }
            }
            if let last = splitter.flush() { sink.append([last]) }
            readDone.signal()
        }

        var tail: [String] = []
        var lastOutputAt = Date()
        var stallWarnings = 0
        func drain() {
            let lines = sink.takePending()
            if !lines.isEmpty {
                lastOutputAt = Date()
                stallWarnings = 0
            }
            for line in lines {
                log("   │ \(line)")
                tail.append(line)
            }
            if tail.count > Self.tailLineLimit { tail.removeFirst(tail.count - Self.tailLineLimit) }
        }
        while waitExit(.now() + 0.2) == .timedOut {
            drain()
            let silent = Date().timeIntervalSince(lastOutputAt)
            if RunHookStall.shouldWarn(silentSeconds: silent, warningsSoFar: stallWarnings, threshold: stallThreshold) {
                stallWarnings += 1
                log("⚠️ services: \(label) has produced no output for \(Int(silent.rounded()))s and is still running"
                    + " (pid \(process.processIdentifier)) — fleetest keeps waiting (no timeout); kill pid \(process.processIdentifier) to abort")
            }
        }
        // 終了後の出力は少しだけ回収する(孫が書込端を握っていても EOF を待ち切らない)
        _ = readDone.wait(timeout: .now() + Shell.outputDrainGraceSeconds)
        drain()
        return LongResult(status: process.terminationStatus, tail: tail)
    }
}

/// `ServicesSession.up` の起こし方。run は `forRun` で導く(実機のレーン = LAN 公開・Android 実機 = reverse)。
/// `fleetest services up` はフラグ(`--physical` / `--serial`)から作る(kind = owner)。
struct ServicesUpOptions: Equatable {
    let kind: ServicesLease.Kind
    /// 公開ポートをマシン設定 `services.publishForPhysicalDevices` の LAN アドレスにも束縛する
    let publishForPhysicalDevices: Bool
    /// `adb reverse` を張る Android 実機のシリアル(TCP の公開ポートごと)
    let adbReverseSerials: [String]

    static func forRun(_ resolved: ResolvedProfile) -> ServicesUpOptions { forRun(devices: resolved.devices) }

    static func forRun(devices: [ResolvedDevice]) -> ServicesUpOptions {
        ServicesUpOptions(
            kind: .run,
            publishForPhysicalDevices: devices.contains { $0.spec.isPhysical },
            adbReverseSerials: devices.filter { $0.platform == "android" && $0.spec.isPhysical }.compactMap(\.spec.serial))
    }
}

final class ServicesSession {

    // MARK: 定数

    /// 起動完了の待ちを回す刻み(秒)。コンテナの状態の確認(inspect 約 30〜60ms)を重ねすぎず、起動の検知を遅らせない間隔。
    /// 尽きたとき = なし(待ちの上限は healthcheck の retries × (interval + timeout) + start_period が決める)。
    static let pollIntervalSeconds: Double = 0.25
    /// `run -d` の上限(秒)。Apple はコンテナごとに VM を起こす(§17 の実測で約 1〜2 秒)。刺さったデーモンだけがこれを超える。
    private static let containerStartTimeoutSeconds: Double = 120
    /// Apple のコンテナの IP が割り当てられるのを待つ上限(秒)。起動直後の inspect は未割り当てのことがある。尽きたら起動の失敗。
    private static let addressWaitSeconds: Double = 10
    private static let buildFingerprintLabel = "fleetest-build-fingerprint"

    // MARK: 状態

    private let cli: RuntimeCLI
    private let plan: ServicePlan
    private let stateDir: URL
    private let leaseURL: URL
    private let privateDir: URL
    private let home: String
    private let workspace: ServicesWorkspace
    private let dictionaries: ExpansionDictionaries
    /// compose.yaml の environment が実際に参照した秘密の名前(スクリプトへ渡すのはこれだけ)
    private let usedSecretNames: Set<String>
    private let declaredBuilds: [String: BuildDef]
    /// `adb reverse` を張る Android 実機(run = プロファイルの実機・`services up --serial`)
    private let adbReverseSerials: [String]
    private let interrupt: RunInterruptState?
    /// `service_completed_successfully` の相手 = 前面で実行して終了コードで決着するサービス(`runToCompletion`)
    private let initServices: Set<String>
    /// マシン側 `sandbox.allowedDomains`。空ならプロキシは無い
    private let allowedDomains: [String]
    /// 親のプロキシのポート(loopback のプロキシと同じ番号。計画はこの番号で URL を組み、Apple はゲートウェイの IP にも同じ番号で立てる)
    private let proxyPort: Int?
    /// Apple: run 専用のプロキシ(127.0.0.1・内部サブネットを拒否)と、ゲートウェイの IP からそこへ流す転送器。
    /// 転送器は背景のスレッドが bind に成功したら入る。`gatewayProxyStopped` が立った後は立てない
    private let gatewayProxy = LockedValue<SandboxProxy?>(nil)
    private let gatewayForwarder = LockedValue<ServicesGatewayForwarder?>(nil)
    private let gatewayProxyStopped = LockedValue(false)
    /// 内部ネットワークのゲートウェイとサブネット(作ってから分かる。`<gateway>` の差し替えと NO_PROXY に使う)
    private var internalAddresses: RuntimeListing.NetworkAddresses?
    /// run の冒頭で出した警告(張れなかった `adb reverse`)。run.json の servicesWarnings へ
    private(set) var warnings: [String] = []
    private var lease: ServicesLease
    private var satisfied = Set<String>()
    private var tornDown = false
    private var readySeconds: Double = 0

    private init(cli: RuntimeCLI, plan: ServicePlan, stateDir: URL, privateDir: URL, home: String,
                 workspace: ServicesWorkspace, dictionaries: ExpansionDictionaries, usedSecretNames: Set<String>,
                 declaredBuilds: [String: BuildDef], adbReverseSerials: [String],
                 interrupt: RunInterruptState?, allowedDomains: [String], proxyPort: Int?, lease: ServicesLease) {
        self.cli = cli
        self.plan = plan
        self.stateDir = stateDir
        self.leaseURL = ServicesLeaseFile.directory(stateDir: stateDir)
            .appendingPathComponent(ServicesLeaseFile.fileName(pid: lease.pid, prefix: plan.prefix))
        self.privateDir = privateDir
        self.home = home
        self.workspace = workspace
        self.dictionaries = dictionaries
        self.usedSecretNames = usedSecretNames
        self.declaredBuilds = declaredBuilds
        self.adbReverseSerials = adbReverseSerials
        self.interrupt = interrupt
        self.initServices = Set(plan.containers.flatMap { launch in
            launch.dependsOn.filter { $0.condition == .serviceCompletedSuccessfully }.map(\.service) })
        self.allowedDomains = allowedDomains
        self.proxyPort = proxyPort
        self.lease = lease
    }

    // MARK: 起動

    /// compose.yaml が無ければ nil(何もしない)。`stateDir` は `.fleetest`(控えとロックの置き場)。
    static func up(resolved: ResolvedProfile, stateDir: URL?, options: ServicesUpOptions,
                   interruptState: RunInterruptState? = nil,
                   home: String = NSHomeDirectory(), log: (String) -> Void) throws -> ServicesSession? {
        let workspace = ServicesFacts.workspace(for: resolved)
        guard workspace.hasComposeFile else { return nil }
        guard let stateDir else {
            throw ServicesError(phase: .check, detail: "cannot locate the fleetest state directory (.fleetest), which holds the services lease")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let settings = try ServicesSettings.load()
        let located = try ServicesRuntimeLocator.locate(settings: settings, log: log)
        try refuseIfDockerAPIIsExposed(log: log)
        try ServicesFacts.ensureDataDirectory(workspace)
        let privateDir = try ServicesFacts.makePrivateDirectory(home: home, pid: pid)
        var leaseWritten = false
        do {
            let prepared = try prepare(resolved: resolved, options: options, workspace: workspace, settings: settings,
                                       located: located, privateDir: privateDir, home: home, interrupt: interruptState, log: log)
            let session = ServicesSession(
                cli: prepared.cli, plan: prepared.plan, stateDir: stateDir, privateDir: privateDir, home: home,
                workspace: workspace, dictionaries: prepared.dictionaries, usedSecretNames: prepared.usedSecretNames,
                declaredBuilds: prepared.declaredBuilds,
                adbReverseSerials: options.adbReverseSerials, interrupt: interruptState,
                allowedDomains: prepared.allowedDomains, proxyPort: prepared.proxyPort, lease: prepared.lease)
            // run は `services up` の所有者を引き取る(排他の外で終了を待つ = 所有者も同じ排他の中で片付ける)
            if options.kind == .run { try takeOverOwners(prefix: prepared.plan.prefix, stateDir: stateDir, log: log) }
            try ServicesLock.withLock(prefix: prepared.plan.prefix, stateDir: stateDir) {
                try session.claimPrefix(log: log)
                try session.persist()  // 控えは最初の資源を作る前に書く。書けなければ開始しない
                leaseWritten = true
                do {
                    try session.createAll(log: log)
                } catch {
                    session.teardown(log: log)
                    throw error
                }
            }
            return session
        } catch {
            if !leaseWritten { try? FileManager.default.removeItem(at: privateDir) }
            throw error
        }
    }

    private struct Prepared {
        let cli: RuntimeCLI
        let plan: ServicePlan
        let dictionaries: ExpansionDictionaries
        let usedSecretNames: Set<String>
        let declaredBuilds: [String: BuildDef]
        let allowedDomains: [String]
        let proxyPort: Int?
        let lease: ServicesLease
    }

    /// 資源を作る前の段(読む → 展開 → 正規化 → 検査 → 計画)。中継のイメージだけここで用意する(イメージは片付けの対象ではない)。
    private static func prepare(
        resolved: ResolvedProfile, options: ServicesUpOptions, workspace: ServicesWorkspace, settings: ServicesSettings?,
        located: LocatedRuntime, privateDir: URL, home: String, interrupt: RunInterruptState?, log: (String) -> Void
    ) throws -> Prepared {
        let pid = ProcessInfo.processInfo.processIdentifier
        let dictionaries = try ServicesFacts.dictionaries(project: resolved.project.name, workspace: workspace, home: home)
        let yaml = try ServicesFacts.readText(workspace.composeFile.path, what: "compose.yaml")

        let tree: ComposeValue
        switch ComposeReader.read(yaml: yaml) {
        case .success(let value): tree = value
        case .failure(let refusal): throw refused([refusal], log: log)
        }
        let expanded: ExpandedTree
        switch ComposeTreeExpander.expand(tree, dictionaries: dictionaries) {
        case .success(let value): expanded = value
        case .failure(let refusals): throw refused(refusals.items, log: log)
        }
        let spec: ServiceSpec
        switch ComposeNormalizer.normalize(expanded.value) {
        case .success(let value): spec = value
        case .failure(let refusals): throw refused(refusals.items, log: log)
        }
        if !spec.ignoredTopLevelKeys.isEmpty {
            log("→ services: ignoring top-level key(s) in compose.yaml: " + spec.ignoredTopLevelKeys.joined(separator: ", "))
        }

        // 使った秘密の値は親の出力でも伏せる(コンソール・NDJSON・保存したログ)
        let usedSecretNames = Set(expanded.usedSecretsByService.values.flatMap { $0 })
        SecretRedactor.shared.register(usedSecretNames.compactMap { dictionaries.secrets[$0] })

        let facts = ServicesFacts.pathFacts(for: spec, workspace: workspace)
        let context = ServicesFacts.policyContext(
            runtime: located.kind, workspace: workspace, settings: settings,
            reservedPorts: ServicesFacts.reservedHostPorts(), facts: facts)
        let checked: ComposePolicy.Checked
        switch ComposePolicy.check(spec, context: context) {
        case .success(let value): checked = value
        case .failure(let refusals): throw refused(refusals.items, log: log)
        }

        let dockerConfig = try located.kind == .docker
            ? ServicesFacts.dockerConfigDirectory(privateDir: privateDir, home: home) : nil
        let cli = RuntimeCLI(runtime: located, dockerConfigDirectory: dockerConfig)
        // 中継のイメージは Docker の中継と、両ランタイムの UDP の確認用のエコーに使う
        let needsRelayImage = located.kind == .docker || ServicesFacts.hasUDPPublish(spec)
        let relayImageID = try needsRelayImage
            ? ensureRelayImage(cli: cli, privateDir: privateDir, interrupt: interrupt, log: log) : ""

        // 許可ドメインがあれば親のプロキシ(loopback)。番号を計画に写す(Docker は中継が host.docker.internal:<番号> へ転送・
        // Apple はゲートウェイの IP にも同じ番号で立てる = `createAll`)
        let allowedDomains = (try ScenarioSandbox.plan(settings: try ScenarioSandbox.machineSettings()))?.allowedDomains ?? []
        let proxyPort: Int? = try allowedDomains.isEmpty ? nil : Int(ScriptSandbox.proxy(allowedDomains: allowedDomains).port)

        let workspaceRealpath = ServicesFacts.workspaceRealpath(workspace)
        let generation = ServicesFacts.generation()
        let planOptions = try ServicesFacts.planOptions(
            runtime: located.kind, workspaceRealpath: workspaceRealpath, generation: generation,
            physicalLanes: options.publishForPhysicalDevices, settings: settings,
            relayImageID: relayImageID, spec: spec, proxyPort: proxyPort)
        let plan: ServicePlan
        switch ServicePlanner.make(checked, options: planOptions) {
        case .success(let value): plan = value
        case .failure(let error): throw ServicesError(phase: .check, detail: "cannot plan the services: \(error)")
        }

        var declaredBuilds: [String: BuildDef] = [:]
        var grace: [String: Int] = [:]
        for service in spec.services {
            if let build = service.build { declaredBuilds[service.name] = build }
            if let period = service.stopGracePeriod, let seconds = HealthcheckPolicy.seconds(duration: period) {
                grace[plan.prefix + "-" + service.name] = Int(seconds.rounded(.up))
            }
        }

        var published: [ServicesLease.PublishedPort] = []
        if let relay = plan.relay {
            for forward in relay.forwards where forward.targetService != plan.udpCheck?.echoName {
                published.append(.init(hostIP: forward.hostIP, hostPort: forward.hostPort,
                                       proto: forward.proto.rawValue, service: forward.targetService))
            }
        }
        for launch in plan.containers {
            for binding in launch.publishes {
                published.append(.init(hostIP: binding.hostIP, hostPort: binding.hostPort,
                                       proto: binding.proto.rawValue, service: launch.service))
            }
        }
        let lease = ServicesLease(
            pid: pid, pidStartedAt: ServicesProcessIdentity.startedAtText(pid: pid), kind: options.kind,
            runtime: located.kind.rawValue,
            endpoint: located.endpoint, prefix: plan.prefix, generation: generation, workspace: workspaceRealpath,
            project: resolved.project.name, profile: resolved.runName,
            approvedServices: spec.services.map(\.name), publishedPorts: published,
            secretNames: usedSecretNames.sorted(), stopGraceSeconds: grace, phase: .starting)
        return Prepared(cli: cli, plan: plan, dictionaries: dictionaries, usedSecretNames: usedSecretNames,
                        declaredBuilds: declaredBuilds, allowedDomains: allowedDomains,
                        proxyPort: proxyPort, lease: lease)
    }

    private static func refused(_ refusals: [ComposeRefusal], log: (String) -> Void) -> ServicesError {
        for refusal in refusals { log("✗ services: \(refusal.message)") }
        let first = refusals.first?.message ?? "unknown"
        let more = refusals.count > 1 ? " (+\(refusals.count - 1) more, listed above)" : ""
        return ServicesError(phase: .check, detail: "compose.yaml was refused: \(first)\(more)")
    }

    /// 中継とエコーのイメージ。**起動に使うのはタグではなく image ID**(`docker load` や build が同じタグを上書きできる)。
    private static func ensureRelayImage(cli: RuntimeCLI, privateDir: URL, interrupt: RunInterruptState?,
                                         log: (String) -> Void) throws -> String {
        let tag = RelayImage.tag
        let commands = cli.commands
        if !cli.run(commands.imageInspectID(tag)).succeeded {
            log("→ services: building the relay image \(tag) (first run on this machine; needs network access)")
            let dockerfile = privateDir.appendingPathComponent("relay.Dockerfile")
            let context = privateDir.appendingPathComponent("relay-context")
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
            try ServicesFacts.writePrivateFile(Data(RelayImage.dockerfile.utf8), to: dockerfile)
            let build = cli.runLong(commands.imageBuild(context: context.path, dockerfile: dockerfile.path, tag: tag),
                                    label: "the relay image build", interrupt: interrupt, log: log)
            guard build.status == 0 else {
                throw ServicesError(phase: .build, detail: "building the relay image failed (exit \(build.status))",
                                    logTail: build.tail.suffix(10).joined(separator: "\n"))
            }
        }
        let inspect = cli.run(commands.imageInspectID(tag))
        guard inspect.succeeded, !inspect.trimmed.isEmpty else {
            throw ServicesError(phase: .build, detail: "cannot read the ID of the relay image \(tag) (exit \(inspect.status))",
                                logTail: inspect.tail(lines: 5))
        }
        // Apple の `image inspect` は JSON を返し、`run` が digest 参照を受けるかは未確認 = タグで起こす(ビルドは fleetest だけが行う)
        return cli.isDocker ? inspect.trimmed : tag
    }

    // MARK: スクリプトへ見せるもの(docs/remote-runner.md §17「スクリプト」)

    /// compose.yaml が参照している秘密だけ(名前 → 値)。setup.sh / teardown.sh の環境へ渡す
    var scriptSecrets: [String: String] {
        Dictionary(uniqueKeysWithValues: usedSecretNames.compactMap { name in dictionaries.secrets[name].map { (name, $0) } })
    }

    /// スクリプトが 127.0.0.1 で繋いでよいポート = 宣言した公開ポート(エコーは除く)
    var scriptLoopbackPorts: [UInt16] {
        Set(lease.publishedPorts.map { UInt16(clamping: $0.hostPort) }).sorted()
    }

    /// 中継(`fleetest-services`)の判定の入力。**宣言したサービスだけ**(中継・エコーは入れない = 断られる)
    func gatewayInputs() -> ServiceGatewayInputs {
        var published: [ServicePublication] = []
        if let relay = plan.relay {
            for forward in relay.forwards where forward.targetService != plan.udpCheck?.echoName {
                published.append(ServicePublication(service: forward.targetService, containerPort: forward.targetPort,
                                                    proto: forward.proto, hostIP: forward.hostIP, hostPort: forward.hostPort))
            }
        }
        for launch in plan.containers {
            for binding in launch.publishes {
                published.append(ServicePublication(service: launch.service, containerPort: binding.containerPort,
                                                    proto: binding.proto, hostIP: binding.hostIP, hostPort: binding.hostPort))
            }
        }
        return ServiceGatewayInputs(
            runtime: cli.runtime.kind, executable: cli.runtime.executable, controlEnvironment: cli.controlEnvironment,
            containers: Dictionary(uniqueKeysWithValues: plan.containers.map { ($0.service, $0.name) }),
            published: published)
    }

    // MARK: 同じ接頭辞の控え

    /// 生きている他人の控えがあるときの文言(相手と自分の種類で対処が違う)
    static func heldByOther(_ other: ServicesLease, mine: ServicesLease.Kind) -> String {
        switch (other.kind, mine) {
        case (.run, _):
            return "\(other.holderDescription) holds these services; wait for that run to finish"
        case (.owner, .owner):
            return "these services are already up (\(other.holderDescription)); use them, or run `fleetest services down` first"
        case (.owner, .run):
            // 引き取りの後に別の `services up` が割り込んだときだけ
            return "\(other.holderDescription) holds these services; stop them with `fleetest services down` first"
        }
    }

    /// 生きている所有者(`services up`)の控えがあれば SIGTERM を送り、**排他の外で**終了を待つ(所有者も同じ排他の中で片付けるので、
    /// 握ったまま待つと待ち合う)。所有者は自分の控えの ID だけを消す = 終わった後に run が同じ名前で作れる。
    /// 片付けに失敗して残った控えは孤児として `claimPrefix` が拾う。待ちの上限は所有者の控えから(`ServicesTeardown.teardownBudgetSeconds`)。
    static func takeOverOwners(prefix: String, stateDir: URL, budgetOverrideSeconds: Double? = nil,
                               isAlive: (Int32, String) -> Bool = ServicesProcessIdentity.isAlive,
                               terminate: (Int32) -> Void = { _ = kill($0, SIGTERM) },
                               log: (String) -> Void) throws {
        struct Owner { let pid: Int32; let startedAt: String; let budget: Double }
        let owners: [Owner] = try ServicesLock.withLock(prefix: prefix, stateDir: stateDir, isAlive: isAlive) {
            ServicesLeaseStore.entries(stateDir: stateDir, prefix: prefix).compactMap { entry in
                guard let other = entry.lease, other.kind == .owner,
                      !ServicesLeaseFile.isOrphan(other, isAlive: isAlive) else { return nil }
                log("⚠️ services: taking over the services started by \(other.holderDescription) — this run stops them"
                    + " and starts them again (a run never shares services with a live `services up`)")
                terminate(other.pid)
                return Owner(pid: other.pid, startedAt: other.pidStartedAt,
                             budget: budgetOverrideSeconds ?? ServicesTeardown.teardownBudgetSeconds(lease: other))
            }
        }
        for owner in owners {
            let deadline = now() + owner.budget
            while isAlive(owner.pid, owner.startedAt) {
                if now() >= deadline {
                    throw ServicesError(phase: .start, detail: "the previous owner of these services (`fleetest services up`,"
                        + " pid \(owner.pid)) has not exited \(Int(owner.budget))s after the takeover signal; stop it, then retry")
                }
                Thread.sleep(forTimeInterval: pollIntervalSeconds)
            }
        }
    }

    private func claimPrefix(log: (String) -> Void) throws {
        for entry in ServicesLeaseStore.entries(stateDir: stateDir, prefix: plan.prefix) {
            switch entry.state {
            case .unreadable(let reason):
                throw ServicesError(phase: .start, detail: "an unreadable services lease exists for this workspace"
                    + " (\(entry.url.lastPathComponent): \(reason)), so its services may still be running."
                    + " Inspect them, then run `fleetest services reset --force`")
            case .readable(let other):
                guard ServicesLeaseFile.isOrphan(other, isAlive: ServicesProcessIdentity.isAlive) else {
                    throw ServicesError(phase: .start, detail: Self.heldByOther(other, mine: lease.kind))
                }
                let removed = withoutActuallyEscaping(log) { escapable in
                    ServicesReaper.reapOne(entry: entry, lease: other, home: home,
                                           remover: ServicesReaper.defaultRemover(log: escapable), log: escapable)
                }
                guard removed else {
                    throw ServicesError(phase: .start, detail: "the services left behind by pid \(other.pid) could not be removed;"
                        + " fix the cause or run `fleetest services reset --force`")
                }
            }
        }
        // 控えが無いのに接頭辞の資源が残っている(控えを失った・手で作った)
        let listing = cli.run(cli.commands.listContainers)
        if listing.succeeded {
            let names = RuntimeListing.parse(listing.output, isDocker: cli.isDocker)
                .map(\.name).filter { RuntimeListing.belongs($0, prefix: plan.prefix) }
            if let first = names.first {
                throw ServicesError(phase: .start, detail: "container \(first) already exists without a services lease;"
                    + " run `fleetest services reset --force` to remove it")
            }
        }
    }

    // MARK: 資源の作成

    private func persist() throws {
        try ServicesLeaseStore.write(lease, to: leaseURL)
    }

    private func checkInterrupted() throws {
        if interrupt?.isStopped == true { throw RunInterruptedBeforeStartError(phase: "the services startup") }
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private static func lastLine(_ text: String) -> String {
        text.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private func createAll(log: (String) -> Void) throws {
        let commands = cli.commands
        let begin = Self.now()

        // ネットワーク(内部。Docker は中継の外側も)
        try checkInterrupted()
        let networkNames = [plan.internalNetwork] + plan.userNetworks.values.sorted()
        let needsRelay = plan.relay.map { !$0.forwards.isEmpty || $0.proxyListenPort != nil } ?? false
        for name in networkNames { try createNetwork(name, argv: commands.networkCreate(name)) }
        if needsRelay, let relay = plan.relay {
            try createNetwork(relay.egressNetwork, argv: commands.networkCreateEgress(relay.egressNetwork))
        }
        internalAddresses = inspectNetwork(plan.internalNetwork)
        if proxyPort != nil, !cli.isDocker, internalAddresses?.gateway == nil {
            throw ServicesError(phase: .network, detail: "cannot read the gateway address of network \(plan.internalNetwork), which the proxy must listen on")
        }

        // 名前付きボリューム(無ければ作る。消さない)
        for name in plan.volumes.values.sorted() where !cli.run(commands.volumeInspect(name)).succeeded {
            let created = cli.run(commands.volumeCreate(name))
            guard created.succeeded else {
                throw ServicesError(phase: .start, detail: "creating volume \(name) failed (exit \(created.status))",
                                    logTail: created.tail(lines: 5))
            }
        }

        // イメージ
        let images = try prepareImages(log: log)

        // 中継(Docker)
        let startBegin = Self.now()
        if needsRelay, let relay = plan.relay { try startRelay(relay) }

        // コンテナ
        let hostsFile = try prepareHostsFile()
        startGatewayProxyBinder()
        for launch in plan.containers {
            try checkInterrupted()
            for dependency in launch.dependsOn { try waitFor(dependency) }
            try startContainer(launch, hostsFile: hostsFile, log: log)
        }

        // 全サービスの起動完了(依存先として待った分は済んでいる)
        for launch in plan.containers
        where !satisfied.contains(Self.satisfiedKey(launch.service, .serviceCompletedSuccessfully)) {
            try waitFor(Dependency(service: launch.service, condition: .serviceHealthy))
        }
        let startSeconds = Self.now() - startBegin - readySeconds

        // /udp を公開したときだけ経路を確かめる(サービスの起動の後・setup.sh の前)
        if let check = plan.udpCheck { try runUDPCheck(check, log: log) }

        // Android 実機への reverse(TCP の公開ポートごと。張れたものだけ控えに残す = 解除の対象)
        let tcpPorts = Set(lease.publishedPorts.filter { $0.proto == "tcp" }.map(\.hostPort)).sorted()
        lease.adbReverse = ServicesAdbReverse.addAll(serials: adbReverseSerials, hostPorts: tcpPorts) { line in
            if line.hasPrefix("⚠️") { warnings.append(line) }  // run.json の servicesWarnings へ(合否は変えない)
            log(line)
        }

        lease.phase = .running
        try persist()
        let pull = images.pulled > 0 ? "pull \(Self.format(images.pullSeconds))" : "pull (none)"
        let build = images.built > 0 ? "build \(Self.format(images.buildSeconds))"
            : (images.skipped > 0 ? "build (skipped)" : "build (none)")
        log("→ services: \(pull), \(build), start \(Self.format(startSeconds)), ready \(Self.format(readySeconds))"
            + " (total \(Self.format(Self.now() - begin)))")
    }

    private static func format(_ seconds: Double) -> String { String(format: "%.1fs", seconds) }

    private func createNetwork(_ name: String, argv: [String]) throws {
        try checkInterrupted()
        lease.networks[name] = ""  // 作る前に名前を控える
        try persist()
        let created = cli.run(argv)
        guard created.succeeded else {
            throw ServicesError(phase: .network, detail: "creating network \(name) failed (exit \(created.status))",
                                logTail: created.tail(lines: 5))
        }
        let id = Self.lastLine(created.output)
        lease.networks[name] = id.isEmpty ? name : id
        try persist()
    }

    /// 背景の bind の間隔と上限(秒)。根拠: コンテナの VM の起動は 1〜2 s(§17 の実測)で、ゲートウェイの IP はその後に現れる。
    /// 尽きたとき = 警告を出す(コンテナはプロキシへ繋げず、その失敗はコンテナ側に出る)
    private static let gatewayProxyBindIntervalSeconds: Double = 0.2
    private static let gatewayProxyBindDeadlineSeconds: Double = 30

    /// Apple のコンテナからは Mac の 127.0.0.1 に届かない(§17 の実測)= 内部ネットワークのゲートウェイの IP に、計画と同じ番号で
    /// 道を作る。run 専用のプロキシを 127.0.0.1 に立て(解決した宛先がこの内部ネットワークへ向くもの = DNS rebinding を断る)、
    /// ゲートウェイの IP:番号 からそこへ流す転送器(BSD ソケット。NWListener はブリッジのアドレスに bind できない)を背景で立てる。
    /// **ゲートウェイの IP は最初のコンテナが付いてから Mac のブリッジに現れ、全部外れると消える**(実測)ので、最初のコンテナを
    /// 起こす直前から bind を試み続ける
    private func startGatewayProxyBinder() {
        guard let proxyPort, !cli.isDocker, let gateway = internalAddresses?.gateway else { return }
        let subnet = internalAddresses?.subnet
        let domains = allowedDomains
        let proxyBox = gatewayProxy
        let forwarderBox = gatewayForwarder
        let stopped = gatewayProxyStopped
        let deadline = Date().addingTimeInterval(Self.gatewayProxyBindDeadlineSeconds)
        let began = Date()
        Thread.detachNewThread {
            let proxy: SandboxProxy
            do {
                proxy = try SandboxProxy(allowedDomains: domains,
                                         destinationPolicy: .standard(deniedNetworks: [subnet].compactMap { $0 }))
            } catch {
                ConsoleOut.err("⚠️ services: cannot start the proxy for the containers (\(error.localizedDescription)); containers cannot reach allowedDomains")
                return
            }
            let keepProxy = stopped.withLock { isStopped -> Bool in
                if isStopped { return false }
                proxyBox.value = proxy
                return true
            }
            if !keepProxy { proxy.stop(); return }
            var lastError = "not attempted"
            while Date() < deadline {
                if stopped.value { return }
                do {
                    let forwarder = try ServicesGatewayForwarder(
                        listenAddress: gateway, listenPort: UInt16(clamping: proxyPort), targetPort: proxy.port)
                    let keep = stopped.withLock { isStopped -> Bool in
                        if isStopped { return false }
                        forwarderBox.value = forwarder
                        return true
                    }
                    if !keep { forwarder.stop() }
                    ConsoleOut.out("→ services: proxy for the containers listens on \(gateway):\(proxyPort)"
                        + " (\(String(format: "%.1f", Date().timeIntervalSince(began)))s after the first container was started)")
                    return
                } catch {
                    lastError = error.localizedDescription
                    Thread.sleep(forTimeInterval: Self.gatewayProxyBindIntervalSeconds)
                }
            }
            ConsoleOut.err("⚠️ services: the proxy could not listen on \(gateway):\(proxyPort) within"
                + " \(Int(Self.gatewayProxyBindDeadlineSeconds))s (\(lastError)); containers cannot reach allowedDomains")
        }
    }

    private func inspectNetwork(_ name: String) -> RuntimeListing.NetworkAddresses? {
        let result = cli.run(cli.commands.networkInspect(name))
        guard result.succeeded, let json = RuntimeListing.decodeJSON(result.output) else { return nil }
        return RuntimeListing.networkAddresses(json: json, isDocker: cli.isDocker)
    }

    /// 計画が置いた `<gateway>` を実際のゲートウェイの IP に差し替え、NO_PROXY に内部のサブネットを足す(どちらも作ってから分かる)
    static func resolveProxyEntry(_ entry: EnvEntry, addresses: RuntimeListing.NetworkAddresses?) -> String? {
        guard var value = entry.value else { return nil }
        if let gateway = addresses?.gateway {
            value = value.replacingOccurrences(of: ServicePlanner.gatewayPlaceholder, with: gateway)
        }
        if let subnet = addresses?.subnet, entry.key.lowercased() == "no_proxy",
           !value.split(separator: ",").contains(Substring(subnet)) {
            value += "," + subnet
        }
        return value
    }

    /// `/udp` の公開があるときだけ: エコーを立て、127.0.0.1 の公開ポートへトークンを送って経路を確かめる。
    /// 対象は経路だけ(利用者のサービスは見ない)。**最初は警告だけ**(run は止めない)。終わったらエコーを消す
    private func runUDPCheck(_ check: UDPCheckPlan, log: (String) -> Void) throws {
        try checkInterrupted()
        lease.udpCheck = check.echoName  // 作る前に名前を控える
        try persist()
        let started = cli.run(cli.commands.echoRun(check, network: plan.internalNetwork), timeout: Self.containerStartTimeoutSeconds)
        guard started.succeeded else {
            throw ServicesError(phase: .start, detail: "starting the UDP check echo failed (exit \(started.status))",
                                logTail: started.tail(lines: 5))
        }
        let id = Self.lastLine(started.output)
        lease.udpCheck = id.isEmpty ? check.echoName : id
        try persist()
        defer {
            _ = cli.run(cli.commands.containerRemove(lease.udpCheck ?? check.echoName))
            lease.udpCheck = nil
            try? persist()
        }
        switch ServicesUDPProbe.probeUDP(hostPort: check.udpHostPort) {
        case .reached(let attempt):
            log(UDPReachability.reachedLine(hostPort: check.udpHostPort, attempt: attempt))
        case .unreached(let attempts):
            // 「同じ経路の TCP は届いた」は実際に送って確かめたときだけ書く(エコーは TCP でも待ち受ける)。
            // 届かない経路で run を始めない(アプリの UDP が届かない赤はシナリオの側では原因が見えない)。
            // 呼び手の `up` が巻き戻す(エコーは上の defer・ほかは teardown)
            let tcp = ServicesUDPProbe.probeTCP(hostPort: check.tcpHostPort)
            throw ServicesError(phase: .wait, detail: UDPReachability.failureDetail(
                hostPort: check.udpHostPort, runtime: cli.runtime.kind, attempts: attempts,
                timeoutSeconds: UDPReachability.attemptTimeoutSeconds, tcpReached: tcp, cause: udpCause()))
        }
    }

    /// 原因は確かめられたときだけ: Rancher Desktop(接続先が `~/.rd/` のソケット)の設定が SSH の転送方式のとき
    private func udpCause() -> String? {
        guard cli.isDocker, cli.runtime.endpoint.contains("/.rd/") else { return nil }
        let path = home + "/" + RancherPortForwarding.settingsSubpath
        guard let data = FileManager.default.contents(atPath: path),
              RancherPortForwarding.usesSSHForwarder(settingsJSON: data) == true else { return nil }
        return RancherPortForwarding.cause
    }

    private struct ImageStats {
        var pulled = 0
        var pullSeconds: Double = 0
        var built = 0
        var skipped = 0
        var buildSeconds: Double = 0
    }

    private func prepareImages(log: (String) -> Void) throws -> ImageStats {
        let commands = cli.commands
        var stats = ImageStats()
        var seen = Set<String>()
        for launch in plan.containers {
            try checkInterrupted()
            if launch.build == nil, let reference = launch.image {
                guard seen.insert(reference).inserted else { continue }
                if cli.run(commands.imageInspectID(reference)).succeeded { continue }  // 手元に無いときだけ取る
                log("→ services: pulling \(reference)")
                let began = Self.now()
                let pulled = cli.runLong(commands.imagePull(reference), label: "the pull of \(reference)", interrupt: interrupt, log: log)
                stats.pullSeconds += Self.now() - began
                guard pulled.status == 0 else {
                    throw ServicesError(phase: .pull, detail: "pulling \(reference) failed (exit \(pulled.status))",
                                        logTail: pulled.tail.suffix(10).joined(separator: "\n"))
                }
                stats.pulled += 1
            } else if let build = launch.build {
                let tag = Self.buildTag(launch)
                let inputs: FingerprintInputs
                do {
                    inputs = try ServicesFacts.fingerprintInputs(build: build, platform: launch.platform)
                } catch let error as ServicesError {
                    throw ServicesError(phase: .build, detail: error.detail)
                }
                let fingerprint = FTServices.ServiceBuildFingerprint.compute(inputs)
                let existing = cli.run(commands.imageInspectJSON(tag))
                if existing.succeeded, let json = RuntimeListing.decodeJSON(existing.output),
                   RuntimeListing.firstString(forKey: Self.buildFingerprintLabel, in: json) == fingerprint {
                    stats.skipped += 1
                    continue  // ビルドの中身が変わっていなければ撃たない
                }
                let (context, dockerfile) = try buildPaths(launch: launch, build: build)
                log("→ services: building \(launch.service)")
                let began = Self.now()
                let built = cli.runLong(
                    commands.imageBuild(context: context, dockerfile: dockerfile, tag: tag, args: build.args,
                                        target: build.target, platform: launch.platform,
                                        labels: [Self.buildFingerprintLabel: fingerprint]),
                    label: "the build of \(launch.service)", interrupt: interrupt, log: log)
                stats.buildSeconds += Self.now() - began
                guard built.status == 0 else {
                    throw ServicesError(phase: .build, detail: "building \(launch.service) failed (exit \(built.status))",
                                        logTail: built.tail.suffix(10).joined(separator: "\n"))
                }
                stats.built += 1
            }
        }
        return stats
    }

    private static func buildTag(_ launch: ContainerLaunch) -> String { "\(launch.name):build" }

    /// build context と Dockerfile の引数。**Docker は検査済みの実体パス・Apple は宣言どおりの形**
    /// (`container build` は `/private/…` の context の中身を空で送る。照合は実体パス・渡すのは宣言の形)。
    private func buildPaths(launch: ContainerLaunch, build: BuildDef) throws -> (context: String, dockerfile: String) {
        guard cli.runtime.kind == .apple else {
            return (build.context, build.dockerfile ?? build.context + "/Dockerfile")
        }
        guard let declared = declaredBuilds[launch.service] else {
            throw ServicesError(phase: .build, detail: "no declaration found for the build of \(launch.service)")
        }
        func absolute(_ path: String) -> String {
            let joined = path.hasPrefix("/") ? path : workspace.root.path + "/" + path
            return (joined as NSString).standardizingPath
        }
        let context = absolute(declared.context)
        let dockerfile = absolute(ComposePolicy.dockerfileKey(context: declared.context, dockerfile: declared.dockerfile))
        for path in [context, dockerfile] where path.hasPrefix("/private/") {
            throw ServicesError(phase: .build, detail: "the build path \(path) of \(launch.service) starts with /private/, which Apple Container sends as an empty build context; use a path outside /private (for example under your home directory)")
        }
        return (context, dockerfile)
    }

    private func startRelay(_ relay: RelayPlan) throws {
        let commands = cli.commands
        try checkInterrupted()
        lease.relay = relay.name
        try persist()
        let created = cli.run(commands.relayCreate(relay))
        guard created.succeeded else {
            throw ServicesError(phase: .start, detail: "creating the relay container failed (exit \(created.status))",
                                logTail: created.tail(lines: 5))
        }
        let id = Self.lastLine(created.output)
        lease.relay = id.isEmpty ? relay.name : id
        try persist()
        let connected = cli.run(commands.networkConnect(name: relay.internalNetwork, container: relay.name, alias: nil))
        guard connected.succeeded else {
            throw ServicesError(phase: .network, detail: "connecting the relay to \(relay.internalNetwork) failed (exit \(connected.status))",
                                logTail: connected.tail(lines: 5))
        }
        let started = cli.run(commands.containerStart(relay.name), timeout: Self.containerStartTimeoutSeconds)
        guard started.succeeded else {
            throw ServicesError(phase: .start, detail: "starting the relay container failed (exit \(started.status))"
                + "; a published host port may already be in use", logTail: started.tail(lines: 5))
        }
    }

    // MARK: コンテナ

    /// Apple だけ。`/etc/hosts` にマウントする親専用のファイル(`localhost` を必ず置く)。
    private func prepareHostsFile() throws -> URL? {
        guard cli.runtime.kind == .apple else { return nil }
        let url = privateDir.appendingPathComponent("hosts")
        try ServicesFacts.writePrivateFile(Data("127.0.0.1\tlocalhost\n".utf8), to: url)
        return url
    }

    /// **O_APPEND で追記するだけ**(書き直し = 新しい inode は起動中のコンテナから見えない。§17 の実測)。
    private func appendHost(_ hostsFile: URL, address: String, names: [String]) throws {
        let fd = open(hostsFile.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ServicesError(phase: .start, detail: "cannot open the hosts file: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        let line = Data("\(address)\t\(names.joined(separator: " "))\n".utf8)
        let written = line.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return write(fd, base, buffer.count)
        }
        guard written == line.count else {
            throw ServicesError(phase: .start, detail: "cannot append to the hosts file: \(String(cString: strerror(errno)))")
        }
    }

    private func environmentEntries(for launch: ContainerLaunch) throws -> [EnvEntry] {
        var order: [String] = []
        var values: [String: String] = [:]
        func put(_ key: String, _ value: String?) {
            if values[key] == nil { order.append(key) }
            values[key] = value ?? ""
        }
        for file in launch.envFiles {
            let text = try ServicesFacts.readText(file, what: "env_file")
            // 秘密を参照できない(辞書に秘密があっても env_file の段で拒否される)
            switch DotEnvFile.parse(text, dictionaries: dictionaries) {
            case .success(let pairs): for pair in pairs { put(pair.key, pair.value) }
            case .failure(let refusal): throw ServicesError(phase: .check, detail: "\(file): \(refusal.message)")
            }
        }
        for entry in launch.environment { put(entry.key, entry.value) }
        for entry in launch.proxyEnvironment {  // fleetest の設定が利用者の同名より優先
            put(entry.key, Self.resolveProxyEntry(entry, addresses: internalAddresses))
        }
        return order.map { EnvEntry(key: $0, value: values[$0]) }
    }

    private func startContainer(_ launch: ContainerLaunch, hostsFile: URL?, log: (String) -> Void) throws {
        let commands = cli.commands
        let image = launch.build != nil ? Self.buildTag(launch) : (launch.image ?? "")
        let envFile = try ServicesFacts.writeEnvFile(entries: try environmentEntries(for: launch), into: privateDir, name: launch.service)
        if initServices.contains(launch.service) {
            try runToCompletion(launch, image: image, envFile: envFile, hostsFile: hostsFile, log: log)
            return
        }
        lease.containers[launch.name] = ""  // 作る前に名前を控える
        try persist()
        // Docker は create → 2つ目以降の network connect → start(compose と同じ順。起動直後に別のネットワークの相手を引く
        // サービスが、つなぐ前に落ちない)。Apple は1ネットワークなので run -d
        let argv = cli.isDocker
            ? commands.containerCreate(launch: launch, image: image, envFile: envFile.path)
            : commands.containerRun(launch: launch, image: image, envFile: envFile.path, hostsFile: hostsFile?.path, detached: true)
        let created = cli.run(argv, timeout: Self.containerStartTimeoutSeconds)
        guard created.succeeded else {
            throw ServicesError(phase: .start, detail: "\(cli.isDocker ? "creating" : "starting") \(launch.service) failed (exit \(created.status))",
                                logTail: created.tail(lines: 8))
        }
        let id = Self.lastLine(created.output)
        lease.containers[launch.name] = id.isEmpty ? launch.name : id
        try persist()
        if cli.isDocker {
            for network in launch.networks.dropFirst() {
                let connected = cli.run(commands.networkConnect(name: network, container: launch.name, alias: launch.service))
                guard connected.succeeded else {
                    throw ServicesError(phase: .network, detail: "connecting \(launch.service) to \(network) failed (exit \(connected.status))",
                                        logTail: connected.tail(lines: 5))
                }
            }
            let started = cli.run(commands.containerStart(launch.name), timeout: Self.containerStartTimeoutSeconds)
            guard started.succeeded else {
                throw ServicesError(phase: .start, detail: "starting \(launch.service) failed (exit \(started.status))"
                    + "; a published host port may already be in use", logTail: started.tail(lines: 8))
            }
        } else if let hostsFile {
            let address = try waitForAddress(launch)
            try appendHost(hostsFile, address: address, names: [launch.service])
        }
        log("→ services: started \(launch.service)")
    }

    /// 初期化サービス(`service_completed_successfully` の相手)。**前面で実行し、CLI の終了コード = コンテナの終了コードで決着する**
    /// (Apple Container の `inspect` は終了コードを持たない。前面の `run` が終了コードをそのまま返すのは両ランタイムで実測)。
    /// 期限は置かない(無音の警告は `runLong`)。ネットワークは1つだけ(検査が保証 = 前面実行の後からはつなげない)。
    private func runToCompletion(_ launch: ContainerLaunch, image: String, envFile: URL, hostsFile: URL?,
                                 log: (String) -> Void) throws {
        try checkInterrupted()
        lease.containers[launch.name] = launch.name  // 前面実行は ID を返さない。`--name` で消す
        try persist()
        log("→ services: running \(launch.service) to completion")
        let began = Self.now()
        let result = cli.runLong(
            cli.commands.containerRun(launch: launch, image: image, envFile: envFile.path, hostsFile: hostsFile?.path, detached: false),
            label: "the init service \(launch.service)", interrupt: interrupt, log: log)
        readySeconds += Self.now() - began
        try checkInterrupted()  // 中断で止めた終了コードを「失敗」と言わない
        guard result.status == 0 else {
            throw ServicesError(phase: .wait, detail: "service \(launch.service) exited with code \(result.status)",
                                logTail: result.tail.suffix(20).joined(separator: "\n"))
        }
        satisfied.insert(Self.satisfiedKey(launch.service, .serviceCompletedSuccessfully))
        log("→ services: \(launch.service) completed")
    }

    /// Apple のコンテナの IP(`status.networks[].ipv4Address`。起動直後は未割り当てのことがある)。
    private func waitForAddress(_ launch: ContainerLaunch) throws -> String {
        let deadline = Self.now() + Self.addressWaitSeconds
        while true {
            let inspect = cli.run(cli.commands.containerInspect(launch.name))
            if inspect.succeeded, let json = RuntimeListing.decodeJSON(inspect.output),
               let address = RuntimeListing.appleAddress(json: json) {
                return address
            }
            try checkInterrupted()
            guard Self.now() < deadline else {
                throw ServicesError(phase: .start, detail: "\(launch.service) has no IP address after \(Int(Self.addressWaitSeconds))s",
                                    logTail: inspect.tail(lines: 5))
            }
            Thread.sleep(forTimeInterval: Self.pollIntervalSeconds)
        }
    }

    // MARK: 起動完了の待ち

    private static func satisfiedKey(_ service: String, _ condition: Dependency.Condition) -> String {
        "\(service)|\(condition.rawValue)"
    }

    private func waitFor(_ dependency: Dependency) throws {
        guard let target = plan.containers.first(where: { $0.service == dependency.service }) else { return }
        let key = Self.satisfiedKey(dependency.service, dependency.condition)
        if satisfied.contains(key) { return }
        guard let kind = ReadinessKind.make(condition: dependency.condition, healthcheck: target.healthcheck) else {
            // service_completed_successfully は起動の段で前面実行して決着している(`runToCompletion`)。未決着 = 計画の順序の誤り
            throw ServicesError(phase: .wait, detail: "fleetest did not run \(dependency.service) to completion before a dependent started")
        }
        satisfied.insert(key)
        let began = Self.now()
        defer { readySeconds += Self.now() - began }
        try waitReady(target, kind: kind)
    }

    private func containerState(_ launch: ContainerLaunch) -> RuntimeListing.ContainerStateFact? {
        let inspect = cli.run(cli.commands.containerInspect(launch.name))
        guard inspect.succeeded, let json = RuntimeListing.decodeJSON(inspect.output) else { return nil }
        return RuntimeListing.containerState(json: json, isDocker: cli.isDocker)
    }

    private func probeEvent(_ launch: ContainerLaunch, policy: HealthcheckPolicy) -> ReadinessEvent {
        let argv: [String]
        switch launch.healthcheck?.test {
        case .cmd(let list)?: argv = list
        case .cmdShell(let text)?: argv = ["sh", "-c", text]
        default: argv = []
        }
        // プロキシの変数は healthcheck では空にする(NO_PROXY を読まないクライアントが 127.0.0.1 の検査をプロキシへ送らないように)
        let clearing = launch.proxyEnvironment.map(\.key)
        let result = cli.run(cli.commands.containerExec(launch.name, argv: argv, clearing: clearing), timeout: policy.timeoutSeconds)
        let at = Self.now()
        if result.timedOut { return .probeTimedOut(at: at) }
        return result.succeeded ? .probeSucceeded(at: at) : .probeFailed(at: at)
    }

    private func waitReady(_ launch: ContainerLaunch, kind: ReadinessKind) throws {
        var schedule = ReadinessSchedule(kind: kind, startedAt: Self.now())
        var action: ReadinessAction
        if let state = containerState(launch), state.exited {
            action = schedule.apply(.containerExited(code: state.exitCode, at: Self.now()))
        } else {
            action = schedule.apply(.tick(at: Self.now()))
        }
        while true {
            try checkInterrupted()
            switch action {
            case .ready:
                return
            case .failed(let reason):
                let logs = cli.run(cli.commands.containerLogs(launch.name, tail: 50)).tail(lines: 50)
                throw ServicesError(phase: .wait, detail: "service \(launch.service): \(reason)", logTail: logs)
            case .probe:
                action = schedule.apply(probeEvent(launch, policy: HealthcheckPolicy(launch.healthcheck)))
            case .wait(let until):
                let remaining = until - Self.now()
                if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, Self.pollIntervalSeconds)) }
                if let state = containerState(launch), state.exited {
                    action = schedule.apply(.containerExited(code: state.exitCode, at: Self.now()))
                    continue
                }
                action = schedule.apply(.tick(at: Self.now()))
            }
        }
    }

    // MARK: 失敗の証跡

    /// 各サービスのログの末尾(`ServicePolicy.maxLogLines` 行 = 中継の `logs --tail` の上限と同じ)を `<directory>/services/<service>.log` へ。
    /// setup.sh か run が失敗したときに**片付けの前に**呼ぶ(止めた後は読めない)。失敗は警告だけ(合否を変えない)。
    func saveLogs(to directory: URL, log: (String) -> Void) {
        let target = directory.appendingPathComponent("services")
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            log("⚠️ services: cannot create \(target.path) for the service logs: \(error.localizedDescription)")
            return
        }
        var saved = 0
        for launch in plan.containers where lease.containers[launch.name] != nil {
            let result = cli.run(cli.commands.containerLogs(launch.name, tail: ServicePolicy.maxLogLines))
            guard result.succeeded else {
                log("⚠️ services: cannot read the log of \(launch.service) (exit \(result.status))")
                continue
            }
            let file = target.appendingPathComponent("\(launch.service).log")
            do {
                try result.output.write(to: file, atomically: true, encoding: .utf8)
                saved += 1
            } catch {
                log("⚠️ services: cannot write \(file.path): \(error.localizedDescription)")
            }
        }
        if saved > 0 { log("→ services: saved the log of \(saved) service(s) under \(target.path)") }
    }

    // MARK: 管理口の公開の検知

    /// Docker の管理口(2375 / 2376)が非ループバックで LISTEN なら起動しない(docs/remote-runner.md §17「実行基盤の管理口」。
    /// コンテナがそこへ届くとホストのファイルをマウントできる)。見られなかったときは1行言って進む(「無い」とは言わない)。
    static func refuseIfDockerAPIIsExposed(scan: () -> DockerTCPExposure.Scan = { DockerTCPExposure.scan() },
                                           log: (String) -> Void) throws {
        switch scan() {
        case .clear: break
        case .exposed(let listeners):
            throw ServicesError(phase: .check, detail: "Docker's API is published on TCP at \(DockerTCPExposure.describe(listeners));"
                + " containers could reach it and mount this Mac's files, so the services are not started; \(DockerTCPExposure.remedy)")
        case .unknown(let detail):
            log("→ services: could not check whether Docker's API is published on TCP (\(detail))")
        }
    }

    // MARK: イメージの先行取得(`fleetest services pull`)

    /// 宣言したイメージを今取る(`refresh` = 手元にあっても取り直す)。中継のイメージの初回ビルドも含む(`prepare`)。
    /// サービスは起こさない・控えも書かない。閉じたネットワークでは `services load <file>` で読み込んだ後に run を回す。
    static func pull(resolved: ResolvedProfile, options: ServicesUpOptions, refresh: Bool,
                     home: String = NSHomeDirectory(), log: (String) -> Void) throws -> (pulled: Int, present: Int) {
        let workspace = ServicesFacts.workspace(for: resolved)
        guard workspace.hasComposeFile else {
            throw ServicesError(phase: .check, detail: "no scripts/compose.yaml in \(workspace.root.path)")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let settings = try ServicesSettings.load()
        let located = try ServicesRuntimeLocator.locate(settings: settings, log: log)
        let privateDir = try ServicesFacts.makePrivateDirectory(home: home, pid: pid)
        defer { try? FileManager.default.removeItem(at: privateDir) }
        let prepared = try prepare(resolved: resolved, options: options, workspace: workspace, settings: settings,
                                   located: located, privateDir: privateDir, home: home, interrupt: nil, log: log)
        let cli = prepared.cli
        let commands = cli.commands
        var pulled = 0
        var present = 0
        var seen = Set<String>()
        for launch in prepared.plan.containers where launch.build == nil {
            guard let reference = launch.image, seen.insert(reference).inserted else { continue }
            if !refresh, cli.run(commands.imageInspectID(reference)).succeeded {
                present += 1
                continue
            }
            log("→ services: pulling \(reference)")
            let result = cli.runLong(commands.imagePull(reference), label: "the pull of \(reference)", interrupt: nil, log: log)
            guard result.status == 0 else {
                throw ServicesError(phase: .pull, detail: "pulling \(reference) failed (exit \(result.status))",
                                    logTail: result.tail.suffix(10).joined(separator: "\n"))
            }
            pulled += 1
        }
        return (pulled, present)
    }

    // MARK: 片付け

    /// 通常終了の片付け。**run の成否を変えない**(失敗は警告のみ)。削除に失敗した資源があれば控えを残す。
    func down(log: (String) -> Void) {
        do {
            try ServicesLock.withLock(prefix: plan.prefix, stateDir: stateDir) { teardown(log: log) }
        } catch {
            // 資源は控えの ID で特定できるので、ロックが取れなくても自分のぶんは消せる
            log("⚠️ \(error.localizedDescription) — removing the services without the lock")
            teardown(log: log)
        }
    }

    /// ロックを握った状態で呼ぶ(失敗時の巻き戻しと `down`)。二重に呼んでも無害。
    private func teardown(log: (String) -> Void) {
        guard !tornDown else { return }
        tornDown = true
        gatewayProxyStopped.value = true
        gatewayForwarder.value?.stop()
        gatewayProxy.value?.stop()
        let began = Self.now()
        lease.phase = .tearingDown
        try? persist()
        let remaining = ServicesTeardown.remove(lease: lease, cli: cli, log: log)
        // 親専用の領域(env-file = 秘密の値・hosts・docker config)は資源が残っても要らない(回収は控えの ID で動く)
        try? FileManager.default.removeItem(at: privateDir)
        guard !remaining.hasResources else {
            lease = remaining
            try? persist()
            log("⚠️ services: some resources could not be removed; the lease \(leaseURL.lastPathComponent) is kept"
                + " and the next run (or `fleetest hooks reap`) retries")
            return
        }
        try? FileManager.default.removeItem(at: leaseURL)
        log("→ services: stopped (\(Self.format(Self.now() - began)))")
    }
}
