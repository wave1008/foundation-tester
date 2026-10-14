// コンテナランタイム(Docker / Apple Container)の解決と、ランタイムの CLI を撃つ共通部品(docs/remote-runner.md §17)。
// 選び方・接続先の制約・最低版の門はここだけが持つ。ランタイムの argv は FTServices の RuntimeCommands が作る。

import FTCore
import FTServices
import Foundation

/// サービス(compose.yaml)の失敗。**記録するのはフェーズと事実だけ**(原因の分類は置かない。
/// アプリの初期化の不具合による healthcheck の失敗も同じ顔をする)。
struct ServicesError: Error, LocalizedError, Equatable {
    enum Phase: String, Sendable {
        case check, lock, pull, build, network, start, wait, teardown
    }

    let phase: Phase
    let detail: String
    /// コンテナのログの末尾(あれば)。
    var logTail: String? = nil

    /// run の外(`services status` 等)で見せる形 = 「シナリオは走らなかった」を付けない
    var shortDescription: String {
        var text = "services: \(detail) (phase: \(phase.rawValue))"
        if let logTail, !logTail.isEmpty {
            text += "; last log lines: " + logTail.split(separator: "\n").joined(separator: " | ")
        }
        return text
    }

    /// run の中の失敗 = `RunHookError` と同じく「シナリオは1本も走らなかった」を添える
    var errorDescription: String? { shortDescription + " — no scenario was run" }
}

struct LocatedRuntime: Sendable, Equatable {
    let kind: ServiceRuntime
    /// 絶対パス。
    let executable: String
    /// docker: unix ソケットの実体パス / apple: "apple"。
    let endpoint: String
}

/// ランタイムの CLI の1回ぶんの結果。`Shell.run` は非ゼロで投げないので、成功は `succeeded` で見る。
struct RuntimeCLIResult: Sendable {
    let status: Int32
    let output: String
    let timedOut: Bool
    var succeeded: Bool { status == 0 && !timedOut }
    var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    func tail(lines: Int) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}

/// 解決したランタイムの CLI を撃つ口。**子の環境は制御変数だけを足す**(`/usr/bin/env` 経由なので先頭に NAME=VALUE。
/// サービスへ渡す環境は親専用の env-file だけで、ここには載せない)。
struct RuntimeCLI: Sendable {
    let runtime: LocatedRuntime
    /// "NAME=VALUE" の並び。
    let controlEnvironment: [String]

    /// 短い CLI(inspect / ps / network 等)の上限(秒)。実測はミリ秒〜1秒台で、刺さるのはデーモンの凍結だけ。
    /// 尽きたとき = 子を落として失敗として扱う(`LocalDispatchLock.commandTimeoutSeconds` と同じ規律)。
    static let shortCommandTimeoutSeconds: Double = 60

    /// `dockerConfigDirectory` は fleetest 専有の `DOCKER_CONFIG`(Docker だけ)。
    init(runtime: LocatedRuntime, dockerConfigDirectory: URL? = nil) {
        self.runtime = runtime
        var env: [String] = []
        if runtime.kind == .docker {
            // 接続先を解決時の実体に固定する(DOCKER_HOST / context が後から変わっても同じデーモンに撃つ)
            env.append("DOCKER_HOST=unix://" + runtime.endpoint)
            if let dockerConfigDirectory { env.append("DOCKER_CONFIG=" + dockerConfigDirectory.path) }
        }
        self.controlEnvironment = env
    }

    var isDocker: Bool { runtime.kind == .docker }
    var commands: RuntimeCmds { RuntimeCmds(isDocker: isDocker) }

    func argv(_ args: [String]) -> [String] { controlEnvironment + [runtime.executable] + args }

    func run(_ args: [String], timeout: Double? = RuntimeCLI.shortCommandTimeoutSeconds) -> RuntimeCLIResult {
        do {
            let result = try Shell.run(argv(args), timeout: timeout)
            return RuntimeCLIResult(status: result.status, output: result.output, timedOut: false)
        } catch let ShellError.timedOut(_, seconds) {
            return RuntimeCLIResult(status: -1, output: "timed out after \(Int(seconds))s", timedOut: true)
        } catch {
            return RuntimeCLIResult(status: -1, output: "\(error)", timedOut: false)
        }
    }
}

/// 同名の関数を2つのランタイムから選ぶ。argv の中身は FTServices(純粋)。
struct RuntimeCmds: Sendable {
    let isDocker: Bool

    func networkCreate(_ name: String) -> [String] {
        isDocker ? DockerCommands.networkCreate(name: name) : AppleContainerCommands.networkCreate(name: name)
    }
    /// Docker だけ(中継の外側)。
    func networkCreateEgress(_ name: String) -> [String] { DockerCommands.networkCreateEgress(name: name) }
    func networkRemove(_ name: String) -> [String] {
        isDocker ? DockerCommands.networkRemove(name: name) : AppleContainerCommands.networkRemove(name: name)
    }
    func networkConnect(name: String, container: String, alias: String?) -> [String] {
        DockerCommands.networkConnect(name: name, container: container, alias: alias)
    }
    func volumeCreate(_ name: String) -> [String] {
        isDocker ? DockerCommands.volumeCreate(name: name) : AppleContainerCommands.volumeCreate(name: name)
    }
    func volumeRemove(_ name: String) -> [String] {
        isDocker ? DockerCommands.volumeRemove(name: name) : AppleContainerCommands.volumeRemove(name: name)
    }
    func volumeInspect(_ name: String) -> [String] { ["volume", "inspect", name] }
    func imageInspectID(_ ref: String) -> [String] {
        isDocker ? DockerCommands.imageInspectID(ref: ref) : AppleContainerCommands.imageInspectID(ref: ref)
    }
    /// ラベルの読み取り用(JSON 全体。ラベルは再帰探索で拾う)。
    func imageInspectJSON(_ ref: String) -> [String] { ["image", "inspect", ref] }
    func imagePull(_ ref: String) -> [String] {
        isDocker ? DockerCommands.imagePull(ref: ref) : AppleContainerCommands.imagePull(ref: ref)
    }
    func imageBuild(context: String, dockerfile: String, tag: String, args: [String: String] = [:],
                    target: String? = nil, platform: String? = nil, labels: [String: String] = [:]) -> [String] {
        isDocker
            ? DockerCommands.imageBuild(context: context, dockerfile: dockerfile, tag: tag, args: args,
                                        target: target, platform: platform, labels: labels)
            : AppleContainerCommands.imageBuild(context: context, dockerfile: dockerfile, tag: tag, args: args,
                                                target: target, platform: platform, labels: labels)
    }
    func containerRun(launch: ContainerLaunch, image: String, envFile: String, hostsFile: String?, detached: Bool) -> [String] {
        isDocker
            ? DockerCommands.containerRun(launch: launch, image: image, envFile: envFile, hostsFile: hostsFile, detached: detached)
            : AppleContainerCommands.containerRun(launch: launch, image: image, envFile: envFile, hostsFile: hostsFile, detached: detached)
    }
    /// Docker だけ(Apple は1ネットワークなのでつなぐ段が無く `run -d`)。
    func containerCreate(launch: ContainerLaunch, image: String, envFile: String) -> [String] {
        DockerCommands.containerCreate(launch: launch, image: image, envFile: envFile)
    }
    func relayCreate(_ plan: RelayPlan) -> [String] { DockerCommands.relayCreate(plan: plan) }
    func containerStart(_ name: String) -> [String] {
        isDocker ? DockerCommands.containerStart(name: name) : AppleContainerCommands.containerStart(name: name)
    }
    func containerStop(_ name: String, timeoutSeconds: Int) -> [String] {
        isDocker
            ? DockerCommands.containerStop(name: name, timeoutSeconds: timeoutSeconds)
            : AppleContainerCommands.containerStop(name: name, timeoutSeconds: timeoutSeconds)
    }
    func containerRemove(_ name: String) -> [String] {
        isDocker ? DockerCommands.containerRemove(name: name) : AppleContainerCommands.containerRemove(name: name)
    }
    func containerExec(_ name: String, argv: [String]) -> [String] {
        isDocker ? DockerCommands.containerExec(name: name, argv: argv) : AppleContainerCommands.containerExec(name: name, argv: argv)
    }
    func containerLogs(_ name: String, tail: Int) -> [String] {
        isDocker ? DockerCommands.containerLogs(name: name, tail: tail) : AppleContainerCommands.containerLogs(name: name, tail: tail)
    }
    func containerInspect(_ name: String) -> [String] {
        isDocker ? DockerCommands.containerInspect(name: name) : AppleContainerCommands.containerInspect(name: name)
    }

    // 一覧(接頭辞での絞り込みは呼び手が名前で行う。relay とエコーはラベルを持たないのでラベルの絞り込みは使わない)
    var listContainers: [String] {
        isDocker ? ["ps", "-a", "--format", "{{.ID}}\t{{.Names}}"] : AppleContainerCommands.listByPrefix(prefix: "")
    }
    var listNetworks: [String] {
        isDocker ? ["network", "ls", "--format", "{{.ID}}\t{{.Name}}"] : ["network", "list", "--format", "json"]
    }
    var listVolumes: [String] {
        isDocker ? ["volume", "ls", "--format", "{{.Name}}\t{{.Name}}"] : ["volume", "list", "--format", "json"]
    }
}

/// 一覧の出力から (id, name) を取り出す。Docker は TSV。Apple は JSON で、`ls` / `network list` / `volume list` とも
/// `[{configuration: {…}, id}]`(コンテナは `configuration.id`、ネットワークとボリュームは `id` が名前。1.1.0 の実データ)。
enum RuntimeListing {
    static func parse(_ output: String, isDocker: Bool) -> [(id: String, name: String)] {
        if isDocker {
            return output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2, !parts[1].isEmpty else { return nil }
                return (parts[0], parts[1])
            }
        }
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items = (json as? [Any]) ?? [json]
        return items.compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            let configuration = object["configuration"] as? [String: Any]
            let name = (configuration?["id"] as? String) ?? (object["id"] as? String)
                ?? (object["name"] as? String) ?? (configuration?["name"] as? String)
            guard let name, !name.isEmpty else { return nil }
            return (name, name)
        }
    }

    /// 接頭辞の資源か。内部ネットワークは接頭辞そのもの・ほかは "<接頭辞>-" で始まる。
    static func belongs(_ name: String, prefix: String) -> Bool {
        name == prefix || name.hasPrefix(prefix + "-")
    }

    /// JSON 木の中から、キーが一致する文字列の値を最初に1つ返す(ラベル・アドレス・状態の取り出し)。
    static func firstString(forKey key: String, in json: Any) -> String? {
        if let object = json as? [String: Any] {
            if let value = object[key] as? String { return value }
            for (_, child) in object.sorted(by: { $0.key < $1.key }) {
                if let found = firstString(forKey: key, in: child) { return found }
            }
        } else if let array = json as? [Any] {
            for child in array {
                if let found = firstString(forKey: key, in: child) { return found }
            }
        }
        return nil
    }

    struct ContainerStateFact: Equatable {
        var exited: Bool
        /// 終了したときだけ。Apple Container の `inspect` は終了コードを持たない(1.1.0 の実データ)= nil
        var exitCode: Int32?
    }

    /// `inspect` の JSON(配列1件)。Docker: `State.Status`(exited / dead = 終了)と `State.ExitCode`。
    /// Apple: `status.state`(running / stopped)。形が違えば nil(呼び手は次の周で読み直す)。
    static func containerState(json: Any, isDocker: Bool) -> ContainerStateFact? {
        guard let object = (json as? [Any])?.first as? [String: Any] else { return nil }
        if isDocker {
            guard let state = object["State"] as? [String: Any], let status = state["Status"] as? String else { return nil }
            let exited = status == "exited" || status == "dead"
            return ContainerStateFact(exited: exited, exitCode: exited ? (state["ExitCode"] as? Int).map { Int32($0) } : nil)
        }
        guard let status = object["status"] as? [String: Any], let state = status["state"] as? String else { return nil }
        return ContainerStateFact(exited: state == "stopped", exitCode: nil)
    }

    /// Apple の `inspect`: `status.networks[].ipv4Address`(`192.168.64.4/24` の形。接頭辞長は落とす)。
    /// 未割り当て(`networks` が空)なら nil。
    static func appleAddress(json: Any) -> String? {
        guard let object = (json as? [Any])?.first as? [String: Any],
              let status = object["status"] as? [String: Any],
              let networks = status["networks"] as? [[String: Any]] else { return nil }
        for network in networks {
            if let raw = network["ipv4Address"] as? String, !raw.isEmpty {
                return String(raw.split(separator: "/").first ?? Substring(raw))
            }
        }
        return nil
    }

    static func decodeJSON(_ output: String) -> Any? {
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

enum ServicesRuntimeLocator {
    /// 根拠: §17 の実測の版(container 1.1.0)。若い CLI で `inspect` の JSON の形が変わりうるので下を許さない。
    /// 落ちたらそこで上げる(`BridgeContractTests` と同じ運用)。
    static let minimumAppleContainerVersion = "1.1.0"

    /// `docker info` / `container system status` の上限(秒)。健全なデーモンは1秒未満で返る。
    /// 尽きたとき = そのランタイムは「使えない」(理由に「timed out」と出す)。
    static let probeTimeoutSeconds: Double = 20

    /// `container system start` の上限(秒)。CLI 側の `--timeout` を 60 にして、その外側に余裕を足す。
    static let appleStartTimeoutSeconds: Double = 60
    private static let appleStartShellTimeoutSeconds: Double = 90

    /// 自動(`runtime` 未設定)で Apple の常駐サービスを起こすのは **Docker が使えないときだけ**(起こした上で「両方使える」と
    /// 断るのは無駄で、探すためだけに機械の状態を変える)。明示なら設定どおり。`allowStart` false(`services status`)は常に起こさない。
    static func mayStartApple(explicit: Bool, dockerUsable: Bool, allowStart: Bool) -> Bool {
        allowStart && (explicit || !dockerUsable)
    }

    /// 探す順は Docker → Apple(`mayStartApple` が Docker の結果を見る)。
    static func locate(
        settings: ServicesSettings?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowStart: Bool = true,
        log: (String) -> Void
    ) throws -> LocatedRuntime {
        let wanted: [ServiceRuntime]
        switch settings?.runtime {
        case .docker?: wanted = [.docker]
        case .apple?: wanted = [.apple]
        case nil: wanted = [.docker, .apple]
        }
        let explicit = settings?.runtime != nil

        var usable: [LocatedRuntime] = []
        var reasons: [(ServiceRuntime, String)] = []
        for kind in wanted {
            do {
                let found = try kind == .docker
                    ? probeDocker(environment: environment)
                    : probeApple(environment: environment,
                                 allowStart: mayStartApple(explicit: explicit, dockerUsable: !usable.isEmpty, allowStart: allowStart),
                                 log: log)
                usable.append(found)
            } catch let error as ServicesError {
                if explicit { throw error }
                reasons.append((kind, error.detail))
            }
        }
        if usable.count == 1, let only = usable.first {
            log("→ services: runtime \(only.kind.rawValue) (\(only.executable))")
            return only
        }
        let configPath = LocalConfig.url().path
        if usable.isEmpty {
            let lines = reasons.map { "\($0.0 == .docker ? "Docker" : "Apple Container"): \($0.1)" }
            throw ServicesError(
                phase: .check,
                detail: "no container runtime is usable — " + lines.joined(separator: "; ")
                    + ". Install and start Docker (or Rancher Desktop) or Apple Container;"
                    + " set \"services\": {\"runtime\": \"docker\" | \"apple\"} in \(configPath) to name one")
        }
        throw ServicesError(
            phase: .check,
            detail: "both Docker and Apple Container are usable; fleetest does not pick one silently."
                + " Set \"services\": {\"runtime\": \"docker\" | \"apple\"} in \(configPath)")
    }

    // MARK: - 候補の探索

    static func dockerCandidates(environment: [String: String], home: String = NSHomeDirectory()) -> [String] {
        let fixed = [
            home + "/.rd/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        return existingExecutables(named: "docker", fixed: fixed, environment: environment)
    }

    static func appleCandidates(environment: [String: String]) -> [String] {
        existingExecutables(named: "container", fixed: ["/opt/homebrew/bin/container", "/usr/local/bin/container"],
                            environment: environment)
    }

    /// PATH の順 → 固定の置き場の順。重複は除く。
    static func existingExecutables(named name: String, fixed: [String], environment: [String: String]) -> [String] {
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        var seen = Set<String>()
        var result: [String] = []
        for path in pathDirs.map({ $0 + "/" + name }) + fixed
        where FileManager.default.isExecutableFile(atPath: path) && seen.insert(path).inserted {
            result.append(path)
        }
        return result
    }

    /// 解決済みの控え(ランタイム名)から実行ファイルだけを引く(デーモンには触らない)。
    static func executable(for kind: ServiceRuntime, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        (kind == .docker ? dockerCandidates(environment: environment) : appleCandidates(environment: environment)).first
    }

    // MARK: - Docker

    private static func probeDocker(environment: [String: String]) throws -> LocatedRuntime {
        let candidates = dockerCandidates(environment: environment)
        guard !candidates.isEmpty else {
            throw ServicesError(phase: .check, detail: "the docker CLI was not found (looked in PATH, ~/.rd/bin, /usr/local/bin, /opt/homebrew/bin, Docker.app)")
        }
        var lastFailure = "the docker daemon did not answer"
        for exe in candidates {
            let info = run([exe, "info", "--format", "{{.ServerVersion}}"], timeout: probeTimeoutSeconds)
            guard info.succeeded, !info.trimmed.isEmpty else {
                lastFailure = info.timedOut ? "`docker info` timed out after \(Int(probeTimeoutSeconds))s"
                    : "`docker info` failed (exit \(info.status)): \(info.tail(lines: 3))"
                continue
            }
            let host = try dockerHost(executable: exe, environment: environment)
            return LocatedRuntime(kind: .docker, executable: exe, endpoint: try unixSocketPath(host))
        }
        throw ServicesError(phase: .check, detail: lastFailure)
    }

    /// `DOCKER_HOST` があればそれ・無ければ現在の context の接続先。
    private static func dockerHost(executable: String, environment: [String: String]) throws -> String {
        if let host = environment["DOCKER_HOST"], !host.isEmpty { return host }
        let context = run([executable, "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
                          timeout: probeTimeoutSeconds)
        guard context.succeeded, !context.trimmed.isEmpty else {
            throw ServicesError(phase: .check, detail: "cannot read the docker context endpoint (`docker context inspect` exit \(context.status)): \(context.tail(lines: 3))")
        }
        return context.trimmed
    }

    /// **この Mac の unix ソケットだけ**: bind の元のパスも公開ポートもそのホストのものになるので、
    /// tcp:// や ssh:// では実体パスの検査と 127.0.0.1 への到達の判断が成り立たない。
    static func unixSocketPath(_ host: String) throws -> String {
        guard host.hasPrefix("unix://") else {
            throw ServicesError(phase: .check, detail: "the docker endpoint is \(host), but only a unix socket on this Mac is supported (a remote or TCP daemon would make bind mounts and published ports refer to another host)")
        }
        let raw = String(host.dropFirst("unix://".count))
        guard raw.hasPrefix("/") else {
            throw ServicesError(phase: .check, detail: "the docker endpoint \(host) is not an absolute unix socket path")
        }
        return ServicesFacts.realPath(raw) ?? raw
    }

    // MARK: - Apple Container

    private static func probeApple(environment: [String: String], allowStart: Bool, log: (String) -> Void) throws -> LocatedRuntime {
        guard let exe = appleCandidates(environment: environment).first else {
            throw ServicesError(phase: .check, detail: "the container CLI was not found (looked in PATH, /opt/homebrew/bin, /usr/local/bin)")
        }
        let version = run([exe, "--version"], timeout: probeTimeoutSeconds)
        guard version.succeeded, let parsed = parseVersion(version.output) else {
            throw ServicesError(phase: .check, detail: "cannot read the container CLI version (`container --version` exit \(version.status)): \(version.tail(lines: 2))")
        }
        guard let minimum = parseVersion(minimumAppleContainerVersion), isVersion(parsed, atLeast: minimum) else {
            throw ServicesError(phase: .check, detail: "container CLI \(parsed.map(String.init).joined(separator: ".")) is older than the supported \(minimumAppleContainerVersion); update Apple Container")
        }
        if run([exe, "system", "status"], timeout: probeTimeoutSeconds).succeeded {
            return LocatedRuntime(kind: .apple, executable: exe, endpoint: "apple")
        }
        guard allowStart else {
            throw ServicesError(phase: .check, detail: "the container system service is not running")
        }
        // カーネルが導入済みなら起動する。未導入だと `--disable-kernel-install` は対話に入らず失敗する
        log("→ services: starting the container system service")
        let start = run([exe, "system", "start", "--disable-kernel-install", "--timeout", String(Int(appleStartTimeoutSeconds))],
                        timeout: appleStartShellTimeoutSeconds)
        guard start.succeeded, run([exe, "system", "status"], timeout: probeTimeoutSeconds).succeeded else {
            throw ServicesError(phase: .check, detail: "the container system service is not running and could not be started"
                + " (exit \(start.status): \(start.tail(lines: 3))); if the Linux kernel is not installed yet,"
                + " run `container system start --enable-kernel-install` once")
        }
        return LocatedRuntime(kind: .apple, executable: exe, endpoint: "apple")
    }

    /// 出力の最初の `X.Y.Z`。
    static func parseVersion(_ text: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+)\\.(\\d+)\\.(\\d+)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let ns = text as NSString
        let parts = (1...3).compactMap { Int(ns.substring(with: match.range(at: $0))) }
        return parts.count == 3 ? parts : nil
    }

    static func isVersion(_ version: [Int], atLeast minimum: [Int]) -> Bool {
        for (a, b) in zip(version, minimum) where a != b { return a > b }
        return true
    }

    private static func run(_ argv: [String], timeout: Double) -> RuntimeCLIResult {
        do {
            let result = try Shell.run(argv, timeout: timeout)
            return RuntimeCLIResult(status: result.status, output: result.output, timedOut: false)
        } catch let ShellError.timedOut(_, seconds) {
            return RuntimeCLIResult(status: -1, output: "timed out after \(Int(seconds))s", timedOut: true)
        } catch {
            return RuntimeCLIResult(status: -1, output: "\(error)", timedOut: false)
        }
    }
}
