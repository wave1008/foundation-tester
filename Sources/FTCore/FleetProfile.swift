// FleetProfile.swift
// フリート定義(TestProjects/<project>/profiles/fleets/<name>.json。docs/remote-runner.md
// §13「フリート実行」)。ssh・プロセス起動はここに置かない(呼び出し側 =
// Sources/ftester/FleetRunner.swift)。ここは読み込み・検証・exit code 集約だけの純粋関数。

import Foundation

/// フリートの1エントリ。`host` は "local"(予約語)か RemoteHostRegistry の登録名のみ ——
/// 生の ssh 宛先(user@host)は受け付けない。プロジェクト資産(git 管理)に ssh の実体を
/// 混ぜないため(§13「実行プロファイルに host は埋めない」と同じ理由)。登録名かどうかの
/// 判定は validate(_:project:registeredHostNames:) 側で行う(ここは形だけを保持する)
public struct FleetRunEntry: Codable, Equatable, Sendable {
    public let host: String
    /// profiles/runs/<profile>.json への参照
    public let profile: String

    public init(host: String, profile: String) {
        self.host = host
        self.profile = profile
    }
}

public struct FleetProfileDocument: Codable, Equatable, Sendable {
    public let runs: [FleetRunEntry]

    public init(runs: [FleetRunEntry]) {
        self.runs = runs
    }
}

public enum FleetProfileError: Error, LocalizedError {
    case notFound(name: String, available: [String])
    case decodeFailed(String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name, let available):
            return "fleet not found: \(name)"
                + (available.isEmpty ? " (profiles/fleets/ is empty)"
                   : " (available: \(available.joined(separator: ", ")))")
        case .decodeFailed(let name, let detail):
            return "cannot load fleet \(name): \(detail)"
        }
    }
}

/// フリート定義の静的検証で見つかるエラー。CustomStringConvertible にして
/// 呼び出し側(FleetRunner)が1行ずつ束ねて ValidationError にできるようにする
public enum FleetValidationIssue: Equatable, Sendable, CustomStringConvertible {
    /// "runs" が空
    case emptyRuns
    /// 同じ実行先(登録名 or "local")が2回以上 — デバイスの取り合いになる
    case duplicateHost(String)
    /// "local" でも登録簿の名前でもない(生の ssh 宛先や typo)。**黙ってローカルで走らせない**
    case unregisteredHost(String)
    /// 参照する実行プロファイルが profiles/runs/ に無い
    case unknownRunProfile(host: String, profile: String, available: [String])

    public var description: String {
        switch self {
        case .emptyRuns:
            return "fleet has no \"runs\""
        case .duplicateHost(let host):
            return "duplicate entry for host \"\(host)\""
                + " (dispatching to both fights over the same devices; docs/remote-runner.md §13)"
        case .unregisteredHost(let host):
            return "host \"\(host)\" is neither \"local\" nor a registered host"
                + " (register it with: ftester remote hosts add \(host) --host <user@host>;"
                + " a fleet never falls back to running an unresolved entry locally)"
        case .unknownRunProfile(let host, let profile, let available):
            return "run profile \"\(profile)\" (entry \"\(host)\") not found"
                + (available.isEmpty ? " (profiles/runs/ is empty)"
                   : " (available: \(available.joined(separator: ", ")))")
        }
    }
}

public enum FleetProfile {

    /// profiles/fleets/ のフリート名一覧(拡張子なし、名前順)
    public static func names(project: TestProject) -> [String] {
        jsonNames(in: fleetsDir(project))
    }

    /// **未知キーはエラーにしない**(profiles/runs 等、既存プロファイルの流儀と同じ。
    /// Codable のデフォルト挙動が既にこれを満たすので、専用の警告経路は設けない)
    public static func load(project: TestProject, name: String) throws -> FleetProfileDocument {
        let url = fleetsDir(project).appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FleetProfileError.notFound(name: name, available: names(project: project))
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FleetProfileError.decodeFailed(name, detail: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(FleetProfileDocument.self, from: data)
        } catch {
            throw FleetProfileError.decodeFailed(name, detail: "\(error)")
        }
    }

    /// runs の静的検証。**エラーの集合を返す**(1つ見つけて即 throw しない — 直せる箇所を
    /// 1回で全部言うため)。`registeredHostNames` は呼び出し側が LocalConfig から読んで渡す
    /// (ここを純粋関数に保つため、ファイル I/O はしない)
    public static func validate(
        _ doc: FleetProfileDocument, project: TestProject, registeredHostNames: Set<String>
    ) -> [FleetValidationIssue] {
        guard !doc.runs.isEmpty else { return [.emptyRuns] }

        var issues: [FleetValidationIssue] = []
        var seenHosts: Set<String> = []
        for entry in doc.runs {
            if seenHosts.contains(entry.host) {
                issues.append(.duplicateHost(entry.host))
            }
            seenHosts.insert(entry.host)
        }

        let runProfileNames = Set(ProfileResolver.runProfileNames(project: project))
        for entry in doc.runs {
            if entry.host != "local", !registeredHostNames.contains(entry.host) {
                issues.append(.unregisteredHost(entry.host))
            }
            if !runProfileNames.contains(entry.profile) {
                issues.append(.unknownRunProfile(
                    host: entry.host, profile: entry.profile,
                    available: runProfileNames.sorted()))
            }
        }
        return issues
    }

    /// 集約 exit code: **1つでも非0なら非0**。「どれが落ちたか潰さない」規則として、
    /// 非0の中の最大値を返す(全部同じ 1 に丸めない。複数の異なる exit code が来ても
    /// 一番大きい値の由来だけは exit code から読み取れる)。エントリごとの成否は別途
    /// FleetRunner が1画面の集計として表示する ―― exit code 自体に host 名は乗らない
    public static func aggregateExitCode(_ results: [Int32]) -> Int32 {
        results.filter { $0 != 0 }.max() ?? 0
    }

    static func fleetsDir(_ project: TestProject) -> URL {
        project.profilesDir.appendingPathComponent("fleets")
    }

    private static func jsonNames(in dir: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
