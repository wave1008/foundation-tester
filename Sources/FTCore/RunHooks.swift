// RunHooks.swift
// run の前後で走らせる利用者のスクリプト(docs/remote-runner.md §17)——
// テスト対象が依存する DB・スタブサーバ等をランナー機の上で起こし、終わったら片付けるための口。
// **宣言は無い**: ワークスペースの `scripts/setup.sh` / `scripts/teardown.sh` が
// 存在すれば実行する、それだけ(プロファイルに書く項目を増やさない)。
//
// ここは**パス解決と実行可否の判定だけ**を行う純粋関数(I/O なし)。実際の起動・環境変数の
// 組み立て・孤児の回収は Sources/fleetest/RunHookRunner.swift。

import Foundation

/// 解決済みのフック1本
public struct RunHook: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case setup, teardown

        /// ファイル名。**固定**(プロファイルで名前を変えられるようにはしない ——
        /// 置き場所と名前が1つに決まっているほうが、受け手にも回収側にも読み違えが起きない)
        public var script: String {
            switch self {
            case .setup: return "setup.sh"
            case .teardown: return "teardown.sh"
            }
        }
    }

    public let kind: Kind
    /// 絶対パス(`<workspace>/scripts/<script>`)
    public let url: URL

    public init(kind: Kind, url: URL) {
        self.kind = kind
        self.url = url
    }
}

public enum RunHookPlan {

    /// スクリプトを置くフォルダ(ワークスペース直下)。WorkspaceScaffold.directoryNames と同期
    public static let scriptsDirectoryName = "scripts"

    /// ワークスペースから1本を解決する(パス計算だけ。ファイルの有無は見ない)
    public static func resolve(kind: RunHook.Kind, workspaceRoot: URL) -> RunHook {
        RunHook(
            kind: kind,
            url: workspaceRoot.appendingPathComponent(scriptsDirectoryName)
                .appendingPathComponent(kind.script))
    }

    /// **あれば実行、無ければ何もしない**。ワークスペースは常に有効なので、スクリプトを
    /// 使わない利用者に空ファイルの作成を強いない(「宣言したのに無い」という状態が
    /// そもそも作れないので、置き忘れをエラーにする道は無い)
    public enum Action: Equatable {
        case run
        case skip
    }

    public static func action(for hook: RunHook, exists: Bool) -> Action {
        exists ? .run : .skip
    }
}

/// フックへ渡す環境変数(docs/remote-runner.md §17)。**利用者のスクリプトが読む契約**なので、
/// 増減はドキュメントと同時に行う。
///
/// **値が無くてもキーは必ず置く**(空文字列)。孤児の回収から撃つ終了スクリプトは run の
/// 文脈を持たないため一部が空になるが、キー自体を落とすと呼び出し元で `set -u` が
/// 「未定義」で落ち、片付けだけができなくなる。
///
/// エミュレータ/シミュレータの serial・udid は**ここには載らない** —— 実体の解決
/// (avd → adb serial、デバイス名 → シミュレータ UDID)は run の中でワーカーを組むときに
/// 起きるので、開始スクリプトの時点ではまだ決まっていない。必要なスクリプトは
/// `adb devices` / `xcrun simctl list` を自分で叩く
public enum RunHookEnvironment {

    public static func variables(
        kind: RunHook.Kind, workspace: URL, project: String, profile: String,
        machine: String, reportDir: URL?, iosDevices: [String], androidDevices: [String]
    ) -> [String: String] {
        [
            "FT_HOOK": kind.rawValue,
            "FT_WORKSPACE": workspace.path,
            "FT_PROJECT": project,
            "FT_PROFILE": profile,
            "FT_MACHINE": machine,
            "FT_REPORT_DIR": reportDir?.path ?? "",
            "FT_IOS_DEVICES": iosDevices.joined(separator: " "),
            "FT_ANDROID_DEVICES": androidDevices.joined(separator: " "),
        ]
    }

    public static func variables(kind: RunHook.Kind, profile: ResolvedProfile) -> [String: String] {
        variables(
            kind: kind,
            workspace: profile.workspaceRoot ?? profile.project.rootURL,
            project: profile.project.name, profile: profile.runName,
            machine: profile.machineName, reportDir: profile.reportDir,
            iosDevices: profile.iosDevices.map(\.name),
            androidDevices: profile.androidDevices.map(\.name))
    }

    /// 孤児の回収から撃つ終了スクリプト用(run の文脈が無い)
    public static func variables(orphan info: RunHookLeaseInfo) -> [String: String] {
        variables(
            kind: .teardown, workspace: URL(fileURLWithPath: info.workspace),
            project: info.project, profile: info.profile, machine: "", reportDir: nil,
            iosDevices: [], androidDevices: [])
    }
}

/// 終了スクリプトの実行保証(docs/remote-runner.md §17)。開始スクリプトを撃つ**前**に置き、
/// 終了スクリプトを撃ったら消す。プロセスが defer に到達できずに死んだ場合
/// (ssh 切断の SIGHUP・SIGKILL・停電)にここだけが残り、次の run と `remote clean` が
/// これを見て終了スクリプトを代わりに撃つ —— 掴まれたままのポートで次のディスパッチが
/// 全部落ちるのを防ぐ。
///
/// **生存判定は pid だけ**(RunLease と違い mtime は見ない)。run は数十分かかりうるので、
/// 無音の時間で「古い」と判定すると**動いている run の DB を落とす**。pid 再利用で
/// 生きていると誤認する側へ倒れるが、その pid が死ねば次の回収で拾える
public struct RunHookLeaseInfo: Codable, Equatable, Sendable {
    public let pid: Int32
    public let project: String
    public let profile: String
    /// 絶対パス。回収側はこのファイルをそのまま撃つ(プロファイルを読み直さない ——
    /// 孤児を残した run のプロファイルは既に書き換えられているかもしれない)
    public let teardown: String
    public let workspace: String
    public let startedAt: String

    public init(pid: Int32, project: String, profile: String,
                teardown: String, workspace: String, startedAt: String) {
        self.pid = pid
        self.project = project
        self.profile = profile
        self.teardown = teardown
        self.workspace = workspace
        self.startedAt = startedAt
    }

    public static func now(pid: Int32, project: String, profile: String,
                           teardown: URL, workspace: URL, date: Date = Date()) -> RunHookLeaseInfo {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return RunHookLeaseInfo(
            pid: pid, project: project, profile: profile,
            teardown: teardown.path, workspace: workspace.path,
            startedAt: formatter.string(from: date))
    }
}

public enum RunHookLease {

    /// `<stateDir>/hooks/`(stateDir = リポジトリルートの `.fleetest`)。**プロジェクト非依存**
    /// —— 孤児が掴んでいるのはポートというホスト全体の資源で、次に走る run が別プロジェクトでも
    /// 同じ衝突を起こす(RemoteDispatchLock がホストに1本なのと同じ理由)
    public static func directory(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("hooks")
    }

    public static func leaseURL(stateDir: URL, pid: Int32) -> URL {
        directory(stateDir: stateDir).appendingPathComponent("\(pid).json")
    }

    public static func encode(_ info: RunHookLeaseInfo) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(info) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ raw: String) -> RunHookLeaseInfo? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RunHookLeaseInfo.self, from: data)
    }

    /// 回収対象か(= 記録した run のプロセスがもう居ないか)。判定を純粋関数で持つのは、
    /// テストが kill(2) を使わずに固定できるようにするため
    public static func isOrphan(_ info: RunHookLeaseInfo, isAlive: (Int32) -> Bool) -> Bool {
        guard info.pid > 0 else { return true }  // 壊れた記録は回収して消す(残すと永久に溜まる)
        return !isAlive(info.pid)
    }

    /// 既定の生存判定。定義元は `ProcessLiveness`(判定は1箇所に置く)。ここは呼び手の綴りを
    /// 変えないための転送
    public static func processIsAlive(_ pid: Int32) -> Bool {
        ProcessLiveness.isAlive(pid)
    }

    /// 転送(doc は `ProcessLiveness.isAliveState` 参照)
    public static func isAliveState(_ pStat: Int32, flags: Int32 = 0) -> Bool {
        ProcessLiveness.isAliveState(pStat, flags: flags)
    }
}
