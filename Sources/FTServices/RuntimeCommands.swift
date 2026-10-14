// ServicePlan の型 → ランタイム CLI の argv。純粋(実行ファイルのパスは含めない。呼び手が先頭に付ける)。
// 同名の関数を2つのランタイムに持たせ、呼び手がランタイムで分岐しやすくする。
// Apple Container のフラグは container 1.1.0 の `--help` で確かめた形(network create --internal / volume create・delete /
// image load -i / build の --build-arg・--target・--platform・--label / run の -m・-c・--tmpfs・--env-file・--entrypoint・--init・--label /
// stop -t / rm -f / logs -n / ls --format json)。`inspect` の JSON の形(`status.state`・`status.networks[].ipv4Address`・
// 終了コードの欄は無い)と、前面の `run` / `exec` が終了コードをそのまま返すことも 1.1.0 で実測(`RuntimeListing`)。
// 秘密はコマンドラインに載せない: 環境は envFile の `--env-file` だけで渡す(`-e` は使わない)。

import Foundation

/// 両ランタイムで共通の組み立て。差は `isDocker` で分ける。
private enum RuntimeArgv {
    static func sortedPairs(_ dict: [String: String], flag: String) -> [String] {
        dict.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            .flatMap { [flag, "\($0)=\(dict[$0] ?? "")"] }
    }

    static func portSpec(hostIP: String, hostPort: Int, containerPort: Int, proto: PortPublish.Proto) -> String {
        let base = "\(hostIP):\(hostPort):\(containerPort)"
        return proto == .udp ? base + "/udp" : base
    }

    static func cpusText(_ cpus: Double, isDocker: Bool) -> String {
        if !isDocker { return String(Int(cpus.rounded(.up))) }
        return cpus == cpus.rounded() ? String(Int(cpus)) : String(cpus)
    }

    static func build(context: String, dockerfile: String, tag: String, args: [String: String],
                      target: String?, platform: String?, labels: [String: String]) -> [String] {
        var argv = ["build", "-f", dockerfile, "-t", tag]
        argv += sortedPairs(args, flag: "--build-arg")
        if let target { argv += ["--target", target] }
        if let platform { argv += ["--platform", platform] }
        argv += sortedPairs(labels, flag: "--label")
        argv.append(context)
        return argv
    }

    /// `head` は `["run", "-d"]`(Apple の常駐サービス)/ `["run"]`(初期化サービス = 前面で実行し、CLI の終了コード =
    /// コンテナの終了コード。両ランタイムで実測)/ `["create"]`(Docker の常駐サービス = つないでから start)。残りは共通。
    static func run(launch: ContainerLaunch, image: String, envFile: String, hostsFile: String?,
                    head: [String], isDocker: Bool) -> [String] {
        var argv = head + ["--name", launch.name]
        // 1つ目のネットワークだけ(2つ目以降は Docker では networkConnect・Apple では検査が断る)
        if let first = launch.networks.first { argv += ["--network", first] }
        if isDocker { for alias in launch.aliases { argv += ["--network-alias", alias] } }
        for p in launch.publishes {
            argv += ["-p", portSpec(hostIP: p.hostIP, hostPort: p.hostPort, containerPort: p.containerPort, proto: p.proto)]
        }
        for m in launch.mounts {
            argv += ["-v", "\(m.source):\(m.target)" + (m.readOnly ? ":ro" : "")]
        }
        if !isDocker, let hostsFile { argv += ["-v", "\(hostsFile):/etc/hosts"] }
        argv += ["--env-file", envFile]
        argv += sortedPairs(launch.labels, flag: "--label")
        if let mem = launch.memLimit { argv += [isDocker ? "--memory" : "-m", mem] }
        if let cpus = launch.cpus { argv += [isDocker ? "--cpus" : "-c", cpusText(cpus, isDocker: isDocker)] }
        if launch.initProcess == true { argv.append("--init") }  // 両ランタイムが受ける(container run --init)
        if let user = launch.user { argv += ["--user", user] }
        if let dir = launch.workingDir { argv += ["-w", dir] }
        if let platform = launch.platform { argv += ["--platform", platform] }
        for t in launch.tmpfs { argv += ["--tmpfs", t] }
        var tail: [String] = []
        if let entrypoint = launch.entrypoint, let head = entrypoint.first {
            argv += ["--entrypoint", head]
            tail += entrypoint.dropFirst()
        }
        argv.append(image)
        argv += tail
        argv += launch.command ?? []
        return argv
    }

    static func relayCreate(plan: RelayPlan) -> [String] {
        var argv = ["create", "--name", plan.name, "--network", plan.egressNetwork]
        for f in plan.forwards {
            argv += ["-p", "\(f.hostIP):\(f.hostPort):\(f.hostPort)/\(f.proto.rawValue)"]
        }
        argv += ["--entrypoint", "sh", plan.imageID, "-c", relayScript(plan: plan)]
        return argv
    }

    /// `nodelay` は両側に付ける: 付けないと Nagle で p99 が張り付く(§17「中継のコンテナ」)。
    static func relayScript(plan: RelayPlan) -> String {
        var lines: [String] = []
        for f in plan.forwards {
            switch f.proto {
            case .tcp:
                lines.append("socat TCP-LISTEN:\(f.hostPort),fork,reuseaddr,nodelay TCP:\(f.targetService):\(f.targetPort),nodelay &")
            case .udp:
                lines.append("socat UDP-RECVFROM:\(f.hostPort),fork UDP-SENDTO:\(f.targetService):\(f.targetPort) &")
            }
        }
        if let p = plan.proxyListenPort {
            lines.append("socat TCP-LISTEN:\(p),fork,reuseaddr,nodelay TCP:host.docker.internal:\(p),nodelay &")
        }
        lines.append("wait")
        return lines.joined(separator: "\n")
    }

    static func echoRun(plan: UDPCheckPlan, network: String, publish: Bool) -> [String] {
        var argv = ["run", "-d", "--name", plan.echoName, "--network", network]
        if publish {
            argv += ["-p", "\(plan.hostIP):\(plan.tcpHostPort):\(plan.tcpHostPort)",
                     "-p", "\(plan.hostIP):\(plan.udpHostPort):\(plan.udpHostPort)/udp"]
        }
        let script = "socat TCP-LISTEN:\(plan.tcpHostPort),fork,reuseaddr EXEC:cat & "
            + "socat UDP-RECVFROM:\(plan.udpHostPort),fork EXEC:cat & wait"
        argv += ["--entrypoint", "sh", plan.imageID, "-c", script]
        return argv
    }
}

public enum DockerCommands {
    public static func networkCreate(name: String) -> [String] { ["network", "create", "--internal", name] }
    /// 中継の外側(外へ出られる側)。
    public static func networkCreateEgress(name: String) -> [String] { ["network", "create", name] }
    public static func networkRemove(name: String) -> [String] { ["network", "rm", name] }
    public static func networkConnect(name: String, container: String, alias: String?) -> [String] {
        ["network", "connect"] + (alias.map { ["--alias", $0] } ?? []) + [name, container]
    }

    public static func volumeCreate(name: String) -> [String] { ["volume", "create", name] }
    public static func volumeRemove(name: String) -> [String] { ["volume", "rm", name] }

    public static func imageInspectID(ref: String) -> [String] { ["image", "inspect", "--format", "{{.Id}}", ref] }
    public static func imagePull(ref: String) -> [String] { ["pull", ref] }
    public static func imageLoad(file: String) -> [String] { ["load", "-i", file] }
    public static func imageBuild(context: String, dockerfile: String, tag: String, args: [String: String] = [:],
                                  target: String? = nil, platform: String? = nil,
                                  labels: [String: String] = [:]) -> [String] {
        RuntimeArgv.build(context: context, dockerfile: dockerfile, tag: tag, args: args, target: target,
                          platform: platform, labels: labels)
    }

    /// hostsFile は Apple だけが使う(Docker は内蔵 DNS)。シグネチャを揃えるために受ける。
    public static func containerRun(launch: ContainerLaunch, image: String, envFile: String,
                                    hostsFile: String? = nil, detached: Bool) -> [String] {
        RuntimeArgv.run(launch: launch, image: image, envFile: envFile, hostsFile: hostsFile,
                        head: detached ? ["run", "-d"] : ["run"], isDocker: true)
    }
    /// 常駐サービスは create → 2つ目以降の `network connect` → start(compose と同じ順。起動直後に別のネットワークの相手を
    /// 引くサービスが、つなぐ前に落ちない)。
    public static func containerCreate(launch: ContainerLaunch, image: String, envFile: String) -> [String] {
        RuntimeArgv.run(launch: launch, image: image, envFile: envFile, hostsFile: nil, head: ["create"], isDocker: true)
    }

    public static func containerStart(name: String) -> [String] { ["start", name] }
    public static func containerStop(name: String, timeoutSeconds: Int) -> [String] {
        ["stop", "-t", String(timeoutSeconds), name]
    }
    public static func containerRemove(name: String, force: Bool = true) -> [String] {
        force ? ["rm", "-f", name] : ["rm", name]
    }
    public static func containerExec(name: String, argv: [String]) -> [String] { ["exec", name] + argv }
    public static func containerLogs(name: String, tail: Int) -> [String] { ["logs", "--tail", String(tail), name] }
    public static func containerInspect(name: String) -> [String] { ["inspect", name] }

    public static func listByPrefix(prefix: String) -> [String] {
        ["ps", "-a", "--filter", "label=\(ServicePlanner.prefixLabel)=\(prefix)", "--format", "{{.ID}}\t{{.Names}}"]
    }

    public static func relayCreate(plan: RelayPlan) -> [String] { RuntimeArgv.relayCreate(plan: plan) }
    public static func relayScript(plan: RelayPlan) -> String { RuntimeArgv.relayScript(plan: plan) }

    /// Docker は公開しない(中継が転送する)。
    public static func echoRun(plan: UDPCheckPlan, network: String) -> [String] {
        RuntimeArgv.echoRun(plan: plan, network: network, publish: false)
    }
}

public enum AppleContainerCommands {
    public static func networkCreate(name: String) -> [String] { ["network", "create", "--internal", name] }
    public static func networkRemove(name: String) -> [String] { ["network", "delete", name] }

    /// `-s` を付けない: 既定は 512 GiB のスパースなイメージで足りる。
    public static func volumeCreate(name: String) -> [String] { ["volume", "create", name] }
    public static func volumeRemove(name: String) -> [String] { ["volume", "delete", name] }

    /// JSON が返る。ID の取り出しは呼び手。
    public static func imageInspectID(ref: String) -> [String] { ["image", "inspect", ref] }
    public static func imagePull(ref: String) -> [String] { ["image", "pull", ref] }
    public static func imageLoad(file: String) -> [String] { ["image", "load", "-i", file] }
    public static func imageBuild(context: String, dockerfile: String, tag: String, args: [String: String] = [:],
                                  target: String? = nil, platform: String? = nil,
                                  labels: [String: String] = [:]) -> [String] {
        RuntimeArgv.build(context: context, dockerfile: dockerfile, tag: tag, args: args, target: target,
                          platform: platform, labels: labels)
    }

    /// cpus は整数に切り上げる(`-c` は個数)。hosts ファイルは `-v <file>:/etc/hosts`(`--mount` は単一ファイルを受けない)。
    public static func containerRun(launch: ContainerLaunch, image: String, envFile: String,
                                    hostsFile: String? = nil, detached: Bool) -> [String] {
        RuntimeArgv.run(launch: launch, image: image, envFile: envFile, hostsFile: hostsFile,
                        head: detached ? ["run", "-d"] : ["run"], isDocker: false)
    }

    public static func containerStart(name: String) -> [String] { ["start", name] }
    public static func containerStop(name: String, timeoutSeconds: Int) -> [String] {
        ["stop", "-t", String(timeoutSeconds), name]
    }
    public static func containerRemove(name: String, force: Bool = true) -> [String] {
        force ? ["rm", "-f", name] : ["rm", name]
    }
    public static func containerExec(name: String, argv: [String]) -> [String] { ["exec", name] + argv }
    public static func containerLogs(name: String, tail: Int) -> [String] { ["logs", "-n", String(tail), name] }
    public static func containerInspect(name: String) -> [String] { ["inspect", name] }

    /// フィルタが無いので全部を返す。呼び手が名前の接頭辞で絞る。
    public static func listByPrefix(prefix: String) -> [String] { ["ls", "-a", "--format", "json"] }

    /// Apple は中継が無く、エコー自身が 127.0.0.1 へ公開する。
    public static func echoRun(plan: UDPCheckPlan, network: String) -> [String] {
        RuntimeArgv.echoRun(plan: plan, network: network, publish: true)
    }
}
