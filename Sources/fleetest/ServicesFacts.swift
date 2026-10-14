// compose.yaml の検査・計画(FTServices の純粋関数)へ渡す入力を、ファイルシステムと設定から集める。
// ここは I/O だけ。判定はしない(パスの実体・symlink・存在は PathFact として渡す)。docs/remote-runner.md §17。

import Darwin
import FTBridgeClient
import FTCore
import FTServices
import Foundation

struct ServicesWorkspace: Sendable, Equatable {
    let root: URL
    let scripts: URL
    let data: URL
    /// scripts/compose.yaml
    let composeFile: URL
    /// scripts/.env
    let dotEnv: URL

    init(root: URL) {
        self.root = root
        scripts = root.appendingPathComponent(RunHookPlan.scriptsDirectoryName)
        data = root.appendingPathComponent("data")
        composeFile = scripts.appendingPathComponent("compose.yaml")
        dotEnv = scripts.appendingPathComponent(".env")
    }

    var hasComposeFile: Bool { FileManager.default.fileExists(atPath: composeFile.path) }
}

enum ServicesFacts {

    // MARK: ワークスペース

    static func workspace(for resolved: ResolvedProfile) -> ServicesWorkspace {
        ServicesWorkspace(root: resolved.workspaceRoot ?? resolved.project.rootURL)
    }

    /// 接頭辞の元。実体パス(無ければ与えられたパス)。
    static func workspaceRealpath(_ workspace: ServicesWorkspace) -> String {
        realPath(workspace.root.path) ?? workspace.root.path
    }

    /// `data/` を親が先に作る(スクリプトに根は作らせない)。symlink や既存のものには触らない。
    static func ensureDataDirectory(_ workspace: ServicesWorkspace) throws {
        var st = stat()
        if lstat(workspace.data.path, &st) == 0 { return }
        try FileManager.default.createDirectory(at: workspace.data, withIntermediateDirectories: true)
    }

    // MARK: パスの事実

    /// symlink を解決した実体パス。`URL.resolvingSymlinksInPath` は `/private` を剥がすので使わない。
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// 宣言の文字列 → 事実。相対パスはワークスペースの root 基準(`scripts/` の親)。
    static func fact(declared: String, base: URL) -> PathFact {
        let joined = declared.hasPrefix("/") ? declared : base.path + "/" + declared
        let symlink = isSymlink(joined)
        guard let real = realPath(joined) else {
            return PathFact(exists: false, realpath: nil, isSymlink: symlink, isDirectory: false)
        }
        var st = stat()
        let isDir = stat(real, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        return PathFact(exists: true, realpath: real, isSymlink: symlink, isDirectory: isDir)
    }

    /// compose に出てくる bind の source・env_file・build.context・dockerfile(鍵は `ComposePolicy.dockerfileKey`)。
    static func pathFacts(for spec: ServiceSpec, workspace: ServicesWorkspace) -> [String: PathFact] {
        var facts: [String: PathFact] = [:]
        let base = workspace.root
        func add(_ declared: String) {
            if facts[declared] == nil { facts[declared] = fact(declared: declared, base: base) }
        }
        for service in spec.services {
            for mount in service.mounts {
                if case let .bind(source, _, _) = mount { add(source) }
            }
            service.envFiles.forEach(add)
            if let build = service.build {
                add(build.context)
                add(ComposePolicy.dockerfileKey(context: build.context, dockerfile: build.dockerfile))
            }
        }
        return facts
    }

    static func policyContext(
        runtime: ServiceRuntime, workspace: ServicesWorkspace, settings: ServicesSettings?,
        reservedPorts: [ClosedRange<Int>], facts: [String: PathFact]
    ) -> ComposePolicy.Context {
        ComposePolicy.Context(
            runtime: runtime,
            scriptsRoot: realPath(workspace.scripts.path) ?? workspace.scripts.path,
            dataRoot: realPath(workspace.data.path) ?? workspace.data.path,
            scriptsRootIsSymlink: isSymlink(workspace.scripts.path),
            dataRootIsSymlink: isSymlink(workspace.data.path),
            buildSources: (settings?.buildSources ?? []).map { realPath($0) ?? $0 },
            pathFacts: facts,
            reservedHostPorts: reservedPorts)
    }

    /// 断るホストのポート。**既存の定数から組む**(ブリッジの探索範囲・Emulator・adb サーバ)。
    static func reservedHostPorts(environment: [String: String] = ProcessInfo.processInfo.environment) -> [ClosedRange<Int>] {
        let bridge = BridgeDiscovery.portRange
        let emulator = AdbLocator.emulatorPorts
        let adb = Int(AdbLocator.adbServerPort(environment: environment))
        return [Int(bridge.lowerBound)...Int(bridge.upperBound),
                Int(emulator.lowerBound)...Int(emulator.upperBound),
                adb...adb]
    }

    // MARK: 変数の辞書

    /// 秘密 = マシン側の `<project>.env`(辞書は空で読む = 秘密の中で秘密を参照しない)。
    /// 普通の変数 = `scripts/.env`(秘密の参照は `.env` の段で拒否される)。
    static func dictionaries(project: String, workspace: ServicesWorkspace, home: String) throws -> ExpansionDictionaries {
        let secretsPath = ServicesSecretsLayout.secretsFile(home: home, project: project)
        var secrets: [String: String] = [:]
        if FileManager.default.fileExists(atPath: secretsPath) {
            let text = try readText(secretsPath, what: "secrets file")
            switch DotEnvFile.parse(text, dictionaries: ExpansionDictionaries()) {
            case .success(let pairs): for pair in pairs { secrets[pair.key] = pair.value }
            case .failure(let refusal):
                throw ServicesError(phase: .check, detail: "secrets file \(secretsPath): \(refusal.message)")
            }
        }
        var plain: [String: String] = [:]
        if FileManager.default.fileExists(atPath: workspace.dotEnv.path) {
            let text = try readText(workspace.dotEnv.path, what: ".env")
            switch DotEnvFile.parse(text, dictionaries: ExpansionDictionaries(secrets: secrets, plain: [:])) {
            case .success(let pairs): for pair in pairs { plain[pair.key] = pair.value }
            case .failure(let refusal):
                throw ServicesError(phase: .check, detail: "\(workspace.dotEnv.path): \(refusal.message)")
            }
        }
        return ExpansionDictionaries(secrets: secrets, plain: plain)
    }

    static func readText(_ path: String, what: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ServicesError(phase: .check, detail: "cannot read \(what) \(path): \(error.localizedDescription)")
        }
    }

    // MARK: ビルドの指紋

    /// `build` は context / dockerfile が実体パスに置き換え済みのもの。`.dockerignore`(context 直下)を適用した
    /// 後のファイルだけを集める(送られるものと一致させる)。ファイルの中身は読まない(Dockerfile を除く)。
    static func fingerprintInputs(build: BuildDef, platform: String?) throws -> FingerprintInputs {
        let contextURL = URL(fileURLWithPath: build.context)
        let ignoreText = (try? String(contentsOf: contextURL.appendingPathComponent(".dockerignore"), encoding: .utf8)) ?? ""
        let rules = DockerIgnore.parse(ignoreText)
        // 否定の規則があるときは、除外した親の配下にも再び含まれるものがありうるので、枝刈りせず全部を判定する
        let canPrune = !rules.contains { $0.negated }

        var files: [FileFact] = []
        func walk(_ directory: String, relative: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
            for name in names.sorted() {
                let rel = relative.isEmpty ? name : relative + "/" + name
                let full = directory + "/" + name
                var st = stat()
                guard lstat(full, &st) == 0 else { continue }
                let type = st.st_mode & S_IFMT
                let ignored = DockerIgnore.isIgnored(rel, rules: rules)
                if type == S_IFDIR {
                    if !ignored {
                        // ディレクトリ自身は大きさ・mtime を持たない(中身が変わるたびに動き、無関係な再ビルドになる)
                        files.append(FileFact(relativePath: rel, size: 0, mtimeNanoseconds: 0,
                                              mode: UInt16(st.st_mode & 0o7777), kind: .directory))
                    }
                    if ignored && canPrune { continue }
                    walk(full, relative: rel)
                } else if !ignored {
                    let nanos = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
                    files.append(FileFact(relativePath: rel, size: Int(st.st_size), mtimeNanoseconds: nanos,
                                          mode: UInt16(st.st_mode & 0o7777),
                                          kind: type == S_IFLNK ? .symlink : .file))
                }
            }
        }
        walk(build.context, relative: "")

        let dockerfilePath = build.dockerfile ?? (build.context + "/Dockerfile")
        let dockerfile = try readText(dockerfilePath, what: "Dockerfile")
        return FingerprintInputs(files: files, dockerfileContents: dockerfile, args: build.args,
                                 target: build.target, platform: platform)
    }

    // MARK: 計画の入力

    static func physicalLanes(resolved: ResolvedProfile) -> Bool {
        resolved.devices.contains { $0.spec.isPhysical }
    }

    static func generation(date: Date = Date(), pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        return "\(stamp)-\(pid)"
    }

    static func hasUDPPublish(_ spec: ServiceSpec) -> Bool {
        spec.services.contains { $0.ports.contains { $0.proto == .udp } }
    }

    static func planOptions(
        runtime: ServiceRuntime, workspaceRealpath: String, generation: String, physicalLanes: Bool,
        settings: ServicesSettings?, relayImageID: String, spec: ServiceSpec
    ) throws -> PlanOptions {
        if physicalLanes && settings?.publishForPhysicalDevices == nil {
            throw ServicesError(phase: .check, detail: "the run includes a physical device, so published ports must be reachable over the LAN;"
                + " set \"services\": {\"publishForPhysicalDevices\": \"<this Mac's IPv4 address>\"} in \(LocalConfig.url().path)")
        }
        if hasUDPPublish(spec) {
            // 確認用のエコーのポート割り当てと到達確認は次の段で入れる(今は ServicePlanner が checkPorts を要求する)
            throw ServicesError(phase: .check, detail: "publishing UDP ports is not supported yet (the UDP reachability check is the next stage)")
        }
        return PlanOptions(
            runtime: runtime, workspaceRealpath: workspaceRealpath, generation: generation,
            physicalLanes: physicalLanes, lanAddress: settings?.publishForPhysicalDevices,
            proxyPort: nil, checkPorts: nil, relayImageID: relayImageID)
    }

    // MARK: 親専用の領域・env-file・資格情報

    /// `~/.config/fleetest/private/<pid>/`(0700)。子(シナリオ・スクリプト)は読めない領域。残骸は死んだ pid のぶんを回収が消す。
    static func makePrivateDirectory(home: String, pid: Int32) throws -> URL {
        let root = URL(fileURLWithPath: ServicesSecretsLayout.privateRoot(home: home))
        let dir = URL(fileURLWithPath: ServicesSecretsLayout.privateDirectory(home: home, pid: pid))
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            _ = chmod(root.path, 0o700)
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            _ = chmod(dir.path, 0o700)
        } catch {
            throw ServicesError(phase: .check, detail: "cannot create the private directory \(dir.path): \(error.localizedDescription)")
        }
        return dir
    }

    /// 0600 で書く(既存は置き換え)。
    static func writePrivateFile(_ data: Data, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)  // 親専用の領域でも symlink は辿らない
        guard fd >= 0 else {
            throw ServicesError(phase: .check, detail: "cannot create \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return write(fd, base, buffer.count)
        }
        guard written == data.count else {
            throw ServicesError(phase: .check, detail: "cannot write \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// `KEY=VALUE` を1行ずつ。**コマンドラインに秘密を載せない**ためのファイル(`--env-file` で渡す)。
    /// 値が無い項目は `KEY=`(`KEY` だけの行は親の環境から継ぐ意味になるので書かない)。
    static func writeEnvFile(entries: [EnvEntry], into privateDir: URL, name: String) throws -> URL {
        var text = ""
        for entry in entries {
            let value = entry.value ?? ""
            // ランタイムの env-file の読み手が黙って落とす・読み違える形(`#` 始まり = コメント・空白や改行を含む名前)を先に断る
            if entry.key.isEmpty || entry.key.hasPrefix("#") || entry.key.contains("=")
                || entry.key.contains(where: { $0.isWhitespace || $0.isNewline }) {
                throw ServicesError(phase: .check, detail: "environment variable name \(entry.key.debugDescription) of \(name) is not valid for an env-file")
            }
            if value.contains("\n") || value.contains("\r") {
                throw ServicesError(phase: .check, detail: "the value of \(entry.key) in \(name) contains a line break, which an env-file cannot carry")
            }
            text += "\(entry.key)=\(value)\n"
        }
        let url = privateDir.appendingPathComponent("\(name).env")
        try writePrivateFile(Data(text.utf8), to: url)
        return url
    }

    /// `DOCKER_CONFIG` 用のディレクトリ。利用者の config.json から **`auths` / `credsStore` / `credHelpers` だけ**を写す
    /// (`proxies` を写すと、認証つきプロキシの URL を Docker がコンテナの環境とビルド引数へ自動注入する)。
    static func dockerConfigDirectory(
        privateDir: URL, home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let dir = privateDir.appendingPathComponent("docker-config")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let sourceDir = environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.docker"
        var copied: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: sourceDir + "/config.json"),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["auths", "credsStore", "credHelpers"] {
                if let value = object[key] { copied[key] = value }
            }
        }
        let out = try JSONSerialization.data(withJSONObject: copied, options: [.sortedKeys])
        try writePrivateFile(out, to: dir.appendingPathComponent("config.json"))
        return dir
    }
}
