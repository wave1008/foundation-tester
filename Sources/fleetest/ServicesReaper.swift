// サービスの控え(`.fleetest/hooks/<pid>~<接頭辞>.json`)の読み取りと、控えの ID による資源の削除
// (docs/remote-runner.md §17「片付けの保証」)。通常終了(ServicesSession.down)・孤児の回収(hooks reap / 次の run)・
// `services reset` が同じ削除を使う。**回収は控えの計画で動き、現在の compose.yaml から作り直さない**。

import FTCore
import FTServices
import Foundation

extension ServicesLease {
    /// 控えに残っている資源があるか(削除に失敗したものだけが残る)。
    var hasResources: Bool {
        !containers.isEmpty || !networks.isEmpty || relay != nil || udpCheck != nil
    }
}

/// 控えのファイル1つ。
struct ServicesLeaseEntry {
    enum State {
        case readable(ServicesLease)
        /// 読めない・版が違う・ファイル名と中身が食い違う。**消さずに報告する**(どの接頭辞かはファイル名で分かる)。
        case unreadable(reason: String)
    }

    let url: URL
    let pid: Int32
    let prefix: String
    let state: State

    var lease: ServicesLease? {
        if case .readable(let lease) = state { return lease }
        return nil
    }
}

enum ServicesLeaseStore {
    /// 接頭辞を渡すと、その接頭辞のファイル名のものだけ。ファイル名が控えの形でないもの(旧形式 `<pid>.json`)は含めない。
    static func entries(stateDir: URL, prefix: String? = nil) -> [ServicesLeaseEntry] {
        let dir = ServicesLeaseFile.directory(stateDir: stateDir)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let parsed = ServicesLeaseFile.parse(fileName: url.lastPathComponent) else { return nil }
            if let prefix, parsed.prefix != prefix { return nil }
            return ServicesLeaseEntry(url: url, pid: parsed.pid, prefix: parsed.prefix, state: load(url, pid: parsed.pid, prefix: parsed.prefix))
        }
    }

    private static func load(_ url: URL, pid: Int32, prefix: String) -> ServicesLeaseEntry.State {
        guard let raw = try? String(contentsOf: url, encoding: .utf8), let lease = ServicesLeaseFile.decode(raw) else {
            return .unreadable(reason: "the file cannot be decoded")
        }
        guard lease.schemaVersion == ServicesLease.currentSchemaVersion else {
            return .unreadable(reason: "schema version \(lease.schemaVersion) (this fleetest reads \(ServicesLease.currentSchemaVersion))")
        }
        guard lease.pid == pid, lease.prefix == prefix else {
            return .unreadable(reason: "the contents do not match the file name")
        }
        return .readable(lease)
    }

    static func write(_ lease: ServicesLease, to url: URL) throws {
        guard let text = ServicesLeaseFile.encode(lease) else {
            throw ServicesError(phase: .start, detail: "cannot encode the services lease")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ServicesError(phase: .start, detail: "cannot write the services lease \(url.path): \(error.localizedDescription)")
        }
    }
}

enum ServicesTeardown {
    /// 停止の猶予の既定(秒)。compose / docker の既定と同じ 10 秒(`stop_grace_period` を宣言したサービスはそちら)。
    /// 控えからの回収(孤児)は宣言を読み直さないのでこの値で止める。
    static let defaultStopGraceSeconds = 10
    /// 中継・エコーは片付けるものを持たない socat なので待たせない。
    static let relayStopGraceSeconds = 2
    /// `stop` 自体の上限に足す余裕(秒)。猶予が尽きて SIGKILL された後の後始末の分。
    private static let stopOverheadSeconds = 30

    static func isGone(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("no such") || text.contains("not found") || text.contains("does not exist")
    }

    /// 削除の失敗の文言が「無い」を表さないことがある(Apple の `network delete` / `volume delete` は
    /// "failed to delete one or more …")。失敗したら一覧で実在を確かめ、載っていなければ消えたとみなす。
    /// 一覧が取れない(nil)なら「ある」(消したと言わない)。Docker の一覧の ID は短縮形なので控えの ID(hex)は前方一致で見る。
    static func absenceConfirmed(name: String, reference: String, listing: [(id: String, name: String)]?) -> Bool {
        guard let listing else { return false }
        let hexReference = reference.count >= 12 && reference.allSatisfy(\.isHexDigit)
        return !listing.contains { entry in
            entry.name == name || entry.name == reference
                || (hexReference && !entry.id.isEmpty && reference.hasPrefix(entry.id))
        }
    }

    /// 失敗したときだけ一覧を1回取る。
    private final class ListingOnce {
        private let cli: RuntimeCLI
        private let argv: [String]
        private var fetched: [(id: String, name: String)]??
        init(cli: RuntimeCLI, argv: [String]) { self.cli = cli; self.argv = argv }
        func get() -> [(id: String, name: String)]? {
            if let fetched { return fetched }
            let result = cli.run(argv)
            let listing: [(id: String, name: String)]? = result.succeeded
                ? RuntimeListing.parse(result.output, isDocker: cli.isDocker) : nil
            fetched = .some(listing)
            return listing
        }
    }

    /// 控えの資源を ID で(無ければ名前で)削除する。**消せなかったものだけが残った控えを返す**。
    /// ボリュームは消さない。
    static func remove(lease: ServicesLease, cli: RuntimeCLI, graceSeconds: [String: Int] = [:],
                       log: (String) -> Void) -> ServicesLease {
        let commands = cli.commands
        var remaining = lease

        // コンテナ(サービス・中継・エコー)は同時に止める。猶予の長いものに合わせて直列に待たない
        struct Target { let key: String; let reference: String; let grace: Int }
        var targets: [Target] = lease.containers.sorted { $0.key < $1.key }.map {
            Target(key: $0.key, reference: $0.value.isEmpty ? $0.key : $0.value,
                   grace: graceSeconds[$0.key] ?? defaultStopGraceSeconds)
        }
        if let relay = lease.relay { targets.append(Target(key: "\u{0}relay", reference: relay, grace: relayStopGraceSeconds)) }
        if let echo = lease.udpCheck { targets.append(Target(key: "\u{0}echo", reference: echo, grace: relayStopGraceSeconds)) }

        let outcomes = LockedValue<[String: (removed: Bool, message: String)]>([:])
        let fixedTargets = targets
        DispatchQueue.concurrentPerform(iterations: fixedTargets.count) { index in
            let target = fixedTargets[index]
            _ = cli.run(commands.containerStop(target.reference, timeoutSeconds: target.grace),
                        timeout: Double(target.grace + stopOverheadSeconds))
            let removal = cli.run(commands.containerRemove(target.reference))
            let gone = removal.succeeded || isGone(removal.output)
            let message = gone ? "" : "container \(target.reference): \(removal.tail(lines: 2))"
            outcomes.withLock { $0[target.key] = (gone, message) }
        }
        let results = outcomes.value
        let containersListed = ListingOnce(cli: cli, argv: commands.listContainers)
        for target in targets {
            guard let outcome = results[target.key] else { continue }
            let name = target.key.hasPrefix("\u{0}") ? target.reference : target.key
            if outcome.removed || absenceConfirmed(name: name, reference: target.reference, listing: containersListed.get()) {
                switch target.key {
                case "\u{0}relay": remaining.relay = nil
                case "\u{0}echo": remaining.udpCheck = nil
                default: remaining.containers.removeValue(forKey: target.key)
                }
            } else {
                log("⚠️ services: could not remove \(outcome.message)")
            }
        }

        // ネットワークはコンテナが消えた後(つながっている間は消せない)
        let networksListed = ListingOnce(cli: cli, argv: commands.listNetworks)
        for (name, id) in lease.networks.sorted(by: { $0.key < $1.key }) {
            let reference = id.isEmpty ? name : id
            let removal = cli.run(commands.networkRemove(reference))
            if removal.succeeded || isGone(removal.output)
                || absenceConfirmed(name: name, reference: reference, listing: networksListed.get()) {
                remaining.networks.removeValue(forKey: name)
            } else {
                log("⚠️ services: could not remove network \(name): \(removal.tail(lines: 2))")
            }
        }
        return remaining
    }
}

struct ServicesReapResult {
    var reaped = 0
    /// 読めない控え。消さずに残してある。
    var unreadable: [URL] = []
    /// 孤児だが削除に失敗した資源が残り、控えを残したもの。
    var kept: [URL] = []
}

enum ServicesReaper {
    /// 控えの資源を消して、残った控え(nil = 全部消えた)を返す。テストは差し替える。
    typealias Remover = (ServicesLease) -> ServicesLease?

    /// 控えの `runtime` / `endpoint` でランタイムを解決する(今の設定ではない)。
    static func defaultRemover(log: @escaping (String) -> Void) -> Remover {
        { lease in
            guard let kind = ServiceRuntime(rawValue: lease.runtime) else {
                log("⚠️ services: the lease of pid \(lease.pid) names an unknown runtime \(lease.runtime.debugDescription); kept")
                return lease
            }
            guard let executable = ServicesRuntimeLocator.executable(for: kind) else {
                log("⚠️ services: the \(lease.runtime) CLI is not installed, so the resources of pid \(lease.pid) cannot be removed; kept")
                return lease
            }
            let cli = RuntimeCLI(runtime: LocatedRuntime(kind: kind, executable: executable, endpoint: lease.endpoint))
            if kind == .apple, !cli.run(["system", "status"]).succeeded {
                log("⚠️ services: the container system service is not running, so the resources of pid \(lease.pid) cannot be removed; kept")
                return lease
            }
            let remaining = ServicesTeardown.remove(lease: lease, cli: cli, log: log)
            return remaining.hasResources ? remaining : nil
        }
    }

    /// 死んだ run が残した控えを片付ける。`fleetest hooks reap` と、同じ接頭辞の run の開始から呼ぶ。
    /// **読めない控えは消さない**(中身が分からないので、資源が残っているかも判定できない)。
    @discardableResult
    static func reap(
        stateDir: URL, home: String = NSHomeDirectory(),
        isAlive: (Int32, String) -> Bool = ServicesProcessIdentity.isAlive,
        remover: Remover? = nil, log: @escaping (String) -> Void
    ) -> ServicesReapResult {
        let remove = remover ?? defaultRemover(log: log)
        var result = ServicesReapResult()
        for entry in ServicesLeaseStore.entries(stateDir: stateDir) {
            switch entry.state {
            case .unreadable(let reason):
                log("⚠️ services: unreadable lease \(entry.url.lastPathComponent) (\(reason)); not removed."
                    + " If its services are gone, run `fleetest services reset --force` for that workspace")
                result.unreadable.append(entry.url)
            case .readable(let lease):
                guard ServicesLeaseFile.isOrphan(lease, isAlive: isAlive) else { continue }
                if reapOne(entry: entry, lease: lease, home: home, remover: remove, log: log) {
                    result.reaped += 1
                } else {
                    result.kept.append(entry.url)
                }
            }
        }
        return result
    }

    /// 孤児1件を片付ける。全部消せたら控えと親専用の領域を消して true。
    static func reapOne(entry: ServicesLeaseEntry, lease: ServicesLease, home: String,
                        remover: Remover, log: (String) -> Void) -> Bool {
        log("🧹 services: removing what run pid \(lease.pid) left behind (prefix \(lease.prefix), \(lease.runtime))")
        if let remaining = remover(lease) {
            try? ServicesLeaseStore.write(remaining, to: entry.url)
            log("⚠️ services: some resources of pid \(lease.pid) could not be removed; the lease is kept for the next attempt")
            return false
        }
        try? FileManager.default.removeItem(at: entry.url)
        removePrivateDirectory(home: home, pid: lease.pid)
        return true
    }

    static func removePrivateDirectory(home: String, pid: Int32) {
        try? FileManager.default.removeItem(atPath: ServicesSecretsLayout.privateDirectory(home: home, pid: pid))
    }
}
