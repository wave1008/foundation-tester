// RemoteDispatch.swift
// `fleetest run --host` (docs/remote-runner.md §3・§7・Phase 1) の純粋ロジック。
// プロセス起動・ネットワーク I/O はここに置かない(呼び出し側 = Sources/fleetest/RemoteRunDispatcher.swift)。

import Foundation
import FTCore

public enum RemoteDispatchError: Error, LocalizedError {
    case invalidHost(String)
    /// 宛先そのものは妥当だが、そのマシンに割り当てられた台が無い(--machine の絞り込み)
    case invalidMachine(String)
    case invalidDevice(String)
    case invalidRemoteDir(String)
    case invalidArtifactsMode(String)
    case incompatible([String])
    case remoteSetupFailed(String)
    case invalidIssuer(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost(let detail):
            return "invalid --machine/--host: \(detail)"
        case .invalidMachine(let detail):
            return "invalid --machine: \(detail)"
        case .invalidDevice(let detail):
            return "invalid --device: \(detail)"
        case .invalidRemoteDir(let detail):
            return "invalid --remote-dir: \(detail)"
        case .invalidArtifactsMode(let detail):
            return "invalid --remote-artifacts: \(detail)"
        case .incompatible(let reasons):
            return (["remote host is not compatible:"] + reasons.map { "  - \($0)" })
                .joined(separator: "\n")
        case .remoteSetupFailed(let detail):
            return "remote setup failed: \(detail)"
        case .invalidIssuer(let detail):
            return "invalid issuer: \(detail)"
        }
    }
}

public struct RemoteHostSpec: Equatable, Sendable {
    public let sshTarget: String

    private init(sshTarget: String) {
        self.sshTarget = sshTarget
    }

    /// "user@host" / "host"。空・空白混じり・"-" 始まり(ssh オプション注入)・
    /// ":" を含む(scp 風の "host:path" の誤用)は拒否する
    public static func parse(_ raw: String) throws -> RemoteHostSpec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteDispatchError.invalidHost("must not be empty: \"\(raw)\"")
        }
        guard !trimmed.contains(where: \.isWhitespace) else {
            throw RemoteDispatchError.invalidHost("must not contain whitespace: \"\(raw)\"")
        }
        guard !trimmed.hasPrefix("-") else {
            throw RemoteDispatchError.invalidHost(
                "must not start with '-' (looks like an ssh option): \"\(raw)\"")
        }
        guard !trimmed.contains(":") else {
            throw RemoteDispatchError.invalidHost(
                "must not contain ':' (use --remote-dir for the remote path): \"\(raw)\"")
        }
        return RemoteHostSpec(sshTarget: trimmed)
    }
}

/// rev 不一致の解消の向き(docs/remote-runner.md §18.3 規則1)。配布モデル上、2人の rev は
/// ほぼ常に祖先関係にある(全員が同じ upstream main を追従)ので、祖先判定だけで向きを決められる
public enum RevisionRelation: String, Sendable {
    case localBehind    // ローカルがランナーの祖先 = この機械が古い
    case remoteBehind   // ランナーがローカルの祖先 = ランナーが古い
    case diverged        // どちらでもない = ブランチ作業
    case unknown         // 判定不能(git を実行できない・ランナーの rev がこの clone に無い等)
}

public enum RemoteCompat {

    /// 呼び手は rev が異なるときだけ呼ぶ契約なので (true, true) は本来起きないが、防御として
    /// .unknown に落とす(default 分岐が nil の組も含めすべて拾う)
    public static func classifyRelation(
        localIsAncestorOfRemote: Bool?, remoteIsAncestorOfLocal: Bool?
    ) -> RevisionRelation {
        switch (localIsAncestorOfRemote, remoteIsAncestorOfLocal) {
        case (true, false): return .localBehind
        case (false, true): return .remoteBehind
        case (false, false): return .diverged
        default: return .unknown
        }
    }

    /// 向き付きの案内(英語1文)。**localBehind は align を実行手順として案内しない** ——
    /// ランナーはピン運用(§18.3)なので、遅れている側の人間が自分を上げる
    public static func relationAdvice(_ relation: RevisionRelation) -> String {
        switch relation {
        case .localBehind:
            return "This machine is behind the runner: update yourself (Scripts/update.sh, or git pull + rebuild)"
                + " — do NOT align the runner backward to match (pinned deployment; docs/remote-runner.md §18.3)."
        case .remoteBehind:
            return "The runner is behind: update it with `fleetest remote align <host>`"
                + " (for a fleet, verify on one host first per the §16.6 canary procedure, then roll out to the rest)."
        case .diverged:
            return "Local and runner revisions have diverged (branch work) — a shared runner cannot track"
                + " both branches; use a dedicated machine for branch verification (docs/remote-runner.md §18.3)."
        case .unknown:
            return "Cannot tell which side is behind (the runner's revision is not in this clone)."
                + " Run `git fetch` and retry — in most cases this machine is the one that is behind."
        }
    }

    /// fail-closed: 片方でも取得できなければ(nil)不一致に含める(古い/未検証の組で
    /// 黙って走らせない。CLAUDE.md「片方だけ変えない」規律をマシン間に広げる)。
    ///
    /// **照合するのは rev と toolchain の2つだけ**。「送り先が想定の機械か」は ssh の宛先
    /// (とホスト鍵)が保証するので、リモートの登録名は見ない
    /// (ProfileResolver.determineMachine の宣言)
    public static func mismatches(
        localRevision: String?, remoteRevision: String?,
        localToolchain: String?, remoteToolchain: String?
    ) -> [String] {
        var reasons: [String] = []
        append(&reasons, label: "git revision", local: localRevision, remote: remoteRevision)
        append(&reasons, label: "toolchain", local: localToolchain, remote: remoteToolchain)
        return reasons
    }

    private static func append(_ reasons: inout [String], label: String,
                               local: String?, remote: String?) {
        switch (local, remote) {
        case let (local?, remote?) where local == remote:
            return
        case let (local?, remote?):
            reasons.append("\(label) mismatch: local=\(local) remote=\(remote)")
        case (nil, let remote?):
            reasons.append("\(label): could not determine the local value (remote=\(remote))")
        case (let local?, nil):
            reasons.append("\(label): could not determine the remote value (local=\(local))")
        case (nil, nil):
            reasons.append("\(label): could not determine the local or remote value")
        }
    }
}

/// リモートホストに用意する専用ベースディレクトリの配置(docs/remote-runner.md 改訂版)。
/// `tool/` = TOOL_ROOT(foundation-tester のクローン。ランナー専用) / `work/` = WORK_DIR
/// (受け手パッケージ。TestProjects・results・.build)。マシンが既に持つローカルインストール
/// (受け手自身の `~/foundation-tester` 等)とは別物にすることで、rsync --delete による
/// ユーザー資産の消失・SPM ビルドロック競合・results DB 混在を避ける
public struct RemoteLayout: Equatable, Sendable {
    public let base: String
    /// 発行者ネームスペースの鍵(§18.2)。resolveLayoutIssuer が検証済みの値を渡す契約
    /// (validateIssuerKey を通していない値をここへ入れない)
    public let issuer: String

    public init(base: String, issuer: String) {
        self.base = Self.stripTrailingSlash(base)
        self.issuer = issuer
    }

    /// **ディレクトリ名は "foundation-tester" 固定**(短くしない)。SPM はパス依存の
    /// パッケージ名をディレクトリ名から導出するため、受け手 Package.swift が宣言する
    /// `package: "foundation-tester"` と一致しないと "unknown package" でマニフェストが
    /// 壊れる(2026-07-31 の localhost E2E で実測)。install.sh の既定
    /// TOOL_ROOT(= WORK_DIR/../foundation-tester)とも揃う。**ツールクローンは
    /// ホスト共有のまま**(発行者ごとに分けない。§18.2/§18.4)
    public var toolRoot: String { base + "/foundation-tester" }
    /// 発行者ごとの WORK_DIR(§18.2)。rsync --delete・results・録画の混線を
    /// ネームスペースで構造的に消す(旧 `<base>/work` は移行期の掃除対象としてのみ RemoteCleanPlan が触る)
    public var workDir: String { base + "/users/" + issuer + "/work" }
    public var binary: String { toolRoot + "/.build/debug/fleetest" }
    /// clean の横断走査(全発行者の work を列挙する)専用
    public var usersDir: String { base + "/users" }

    /// `ProjectStore.projectsDir` が解決する現行の名前と一致必須。片方だけ変えない
    /// (`RemoteDispatchTests.testProjectsDirNameMatchesProjectStore` が固定する)。
    /// WORK_DIR は install.sh が新規に作るものなので旧名 `Projects/` への後方互換は持たない
    public static let projectsDirName = "TestProjects"

    public func projectDir(_ project: String) -> String {
        workDir + "/" + Self.projectsDirName + "/" + project
    }

    /// `remoteControl.workspace` のミラー先(docs/remote-runner.md §17)。
    /// プロジェクトごとに分ける(複数プロジェクトを同じランナーで回しても衝突しない)。
    /// projectDir と違い `--delete` は付いていない側の呼び出し規約は無く、rsync 引数
    /// (RemoteTransferPlan.workspaceRsyncArgs)側で --delete を明示する
    public func workspaceDir(_ project: String) -> String {
        workDir + "/workspace/" + project
    }

    /// ディスパッチ1回分の隔離先(reports のみ。回収後にリモート側で削除する
    /// = RemoteRunDispatcher.cleanupDispatchDir)。stamp は呼び出し側が一意に払い出す
    public func dispatchReportDir(stamp: String) -> String {
        workDir + "/.fleetest/dispatch/" + stamp + "/reports"
    }

    /// `--remote-dir` として受け付ける文字種。**`$` とバッククォートを弾くのが要点** —
    /// remote status はリモート側で `$HOME` を展開させるため二重引用符でパスを囲んでおり
    /// (RemoteStatusProbe.dquote)、`$(…)` や `` ` `` を通すとリモートでコマンド置換が起きる。
    /// パスに要らない文字は入口で落とす(空白も不可 = クォート事故の芽を残さない)
    private static let allowedBaseCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-~")

    /// 入口検証。`resolveBase` の前に必ず呼ぶ(CLI の `--remote-dir` を受ける全経路)
    public static func validateBase(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // 空は既定値へフォールバックする(resolveBase)
        guard trimmed.unicodeScalars.allSatisfy(allowedBaseCharacters.contains) else {
            throw RemoteDispatchError.invalidRemoteDir(
                "must contain only letters, digits and / . _ - ~ : \"\(raw)\"")
        }
    }

    /// `users/<issuer>/` へパスの一部として埋め込む前の文字種検証。base と違い空を許さない
    /// (issuer 不明のまま layout を組み立てさせない = resolveLayoutIssuer が fail fast する契約)
    private static let allowedIssuerCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._-")

    public static func validateIssuerKey(_ raw: String) throws {
        guard !raw.isEmpty, raw.unicodeScalars.allSatisfy(allowedIssuerCharacters.contains) else {
            throw RemoteDispatchError.invalidIssuer(
                "\"\(raw)\" — must be non-empty and contain only letters, digits and @ . _ -"
                + " (set issuerId in ~/.config/fleetest/config.json)")
        }
    }

    /// `--remote-dir` の生値(既定 "~/fleetest-runner")を絶対パスへ解決する。チルダはリモートの
    /// シェルが展開するものであり、ここではローカルで文字列として畳み込む(ssh 越しの `$HOME`
    /// 展開に頼るとコマンド合成が複雑になるため、呼び出し側が事前に1回 `echo $HOME` で取得した
    /// 値をここに渡す)。空/空白のみは既定値にフォールバックする
    public static func resolveBase(_ raw: String, home: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "~/fleetest-runner" : trimmed
        let strippedHome = stripTrailingSlash(home)
        if value == "~" {
            return strippedHome
        }
        if value.hasPrefix("~/") {
            return strippedHome + value.dropFirst(1)
        }
        return value
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        var result = path
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

public enum RemoteTransferPlan {

    /// プロジェクト転送がルート直下で除外する名前(成果物側。実行のたびにリモートで再生成される・
    /// 回収は別経路)。rsyncArgs の `--exclude /<名前>` と projectIgnore の走査の両方がこれを使う
    public static let projectTopLevelExcludes = ["reports", "results", ".fleetest"]
    /// ワークスペースのミラーが階層を問わず除外する名前(.git = ワークスペース自体を git 管理する
    /// ケース / .DS_Store・node_modules = ビルドツール類の一時生成物)
    public static let workspaceExcludesAnywhere = [".git", ".DS_Store", "node_modules"]

    /// プロジェクト転送の対象ツリーにある `.fleetest-transfer-ignore` を読む(rsyncArgs の `ignore`
    /// に渡す)。**3つの呼び手(run のディスパッチ・モニター/デバイスの fan-out・ミラー)が
    /// 同じ走査を使う** —— 片方だけ読まないと「run では残るのに fan-out の転送で台帳が消える」になる
    public static func projectIgnore(project: String, localProjectsDir: String) -> TransferIgnore.Scan {
        TransferIgnore.scan(
            transferRoot: URL(fileURLWithPath: "\(localProjectsDir)/\(project)"),
            skipTopLevel: Set(projectTopLevelExcludes), skipAnywhere: [])
    }

    public static func workspaceIgnore(localWorkspaceDir: String) -> TransferIgnore.Scan {
        TransferIgnore.scan(
            transferRoot: URL(fileURLWithPath: localWorkspaceDir),
            skipTopLevel: [], skipAnywhere: Set(workspaceExcludesAnywhere))
    }

    /// rsync 引数(実行ファイル名は含まない)。順序・末尾スラッシュの有無は rsync の
    /// ディレクトリ同一視の契約なので厳守する。`ignore` は projectIgnore で読んだ結果
    /// (既定値を置かない = 呼び手が読み忘れるとコンパイルで止まる)。**除外は受け側の同じパスを
    /// `--delete` から守る**(TransferIgnore の冒頭。ここが `--exclude` に翻訳する理由)
    public static func rsyncArgs(project: String, localProjectsDir: String,
                                 layout: RemoteLayout, sshTarget: String,
                                 ignore: TransferIgnore.Scan) -> [String] {
        var args = ["-az", "--delete"]
        for name in projectTopLevelExcludes { args += ["--exclude", "/" + name] }
        for pattern in ignore.excludePatterns { args += ["--exclude", pattern] }
        args += [
            "\(localProjectsDir)/\(project)/",
            "\(sshTarget):\(layout.projectDir(project))/",
        ]
        return args
    }

    /// WebView レベリングの供給元キャッシュ(`~/Library/Caches/fleetest/webview`)をランナーへ渡す。
    /// 実機の無い機械はドナー不在で永遠に古いまま(AndroidWebViewUpdate.plan のコメント参照)。
    /// **--delete は付けない**(ランナー自身が吸い出した版を消さない。古い版の掃除は
    /// AndroidWebViewUpdate.run の既存 cleanup が行う)。版で1ファイルなので2回目以降は no-op。
    /// remoteCacheDir はリモートのホーム相対(親ディレクトリは呼び出し側が mkdir -p で用意する)
    public static func webViewCacheRsyncArgs(localCacheDir: String, sshTarget: String,
                                             remoteCacheDir: String) -> [String] {
        ["-az", localCacheDir + "/", "\(sshTarget):\(remoteCacheDir)/"]
    }

    /// `remoteControl.workspace` のミラー(RemoteRunDispatcher が宣言済みのときだけ呼ぶ)。
    /// アプリのパッケージ(.app/.apk)を運ぶための rsync なので `-az --delete` で手元と揃える
    /// (rsyncArgs と同じ規律)。`ignore` は workspaceIgnore で読んだ結果
    public static func workspaceRsyncArgs(localWorkspaceDir: String, project: String,
                                          layout: RemoteLayout, sshTarget: String,
                                          ignore: TransferIgnore.Scan) -> [String] {
        var args = ["-az", "--delete"]
        for name in workspaceExcludesAnywhere { args += ["--exclude", name] }
        for pattern in ignore.excludePatterns { args += ["--exclude", pattern] }
        args += [
            "\(localWorkspaceDir)/",
            "\(sshTarget):\(layout.workspaceDir(project))/",
        ]
        return args
    }
}

public enum RemoteArtifactCollection {

    /// results/ 回収(録画+RunRecorder の run.json/scenario json/host-metrics.ndjson)の rsync 引数。
    /// **--delete は付けない**(RemoteTransferPlan.rsyncArgs と違い、ローカルで別に走った run の
    /// results を巻き添えで消してはいけない)。差分のみ転送するので繰り返し呼んでも安い
    public static func resultsRsyncArgs(project: String, layout: RemoteLayout,
                                        sshTarget: String, localProjectsDir: String) -> [String] {
        rsyncArgs(excludes: [], project: project, layout: layout,
                 sshTarget: sshTarget, localProjectsDir: localProjectsDir)
    }

    /// results/ 回収のうち録画(runs/<runID>/recordings/)だけを除いた rsync 引数。
    /// on-demand モードでも実績 JSON(run.json / scenarios/*.json / host-metrics.ndjson)は
    /// 常に回収する —— 回収しないと LPT(投入順・フリート割り当て)がリモートで走った
    /// シナリオを永久に「実績なし」として扱う。--delete を付けない理由は resultsRsyncArgs と同じ
    public static func recordsOnlyRsyncArgs(project: String, layout: RemoteLayout,
                                            sshTarget: String, localProjectsDir: String) -> [String] {
        rsyncArgs(excludes: ["recordings/"], project: project, layout: layout,
                 sshTarget: sshTarget, localProjectsDir: localProjectsDir)
    }

    private static func rsyncArgs(excludes: [String], project: String, layout: RemoteLayout,
                                  sshTarget: String, localProjectsDir: String) -> [String] {
        var args = ["-az"]
        for exclude in excludes { args += ["--exclude", exclude] }
        args += [
            "\(sshTarget):\(layout.projectDir(project))/results/",
            "\(localProjectsDir)/\(project)/results/",
        ]
        return args
    }
}

extension RemoteArtifactCollection {

    /// 回収済みの録画をランナーから消す1本のコマンド(docs/remote-runner.md §15.4)。
    /// **消すのは録画だけ**(実績 JSON は残す = `remote clean` の保持ポリシーが面倒を見る)。
    ///
    /// **グロブを使わない**。①置き場は `results/runs/<YYYY-MM>/<runID>/recordings`
    /// (RunResultsStore.runDir。月の階層がある)ので `runs/*/recordings` では1件も当たらない
    /// ②ssh の相手はログインシェル(macOS 既定は zsh)で、**マッチしないグロブはそのコマンドを
    /// 失敗させる**(`no matches found`)ため、録画が無い run のたびに警告が出る。
    /// find の `-mindepth/-maxdepth 3` が階層の契約(runs から数えて 月 / runID / recordings)。
    /// runs が無いときは何もしない(`test -d`)= 失敗と区別できる
    public static func deleteRecordingsCommand(project: String, layout: RemoteLayout) -> String {
        let runs = RemoteShell.quote(layout.projectDir(project) + "/results/runs")
        return "if [ -d \(runs) ]; then find \(runs) -mindepth 3 -maxdepth 3 -type d"
            + " -name recordings -exec rm -rf {} +; fi"
    }

    /// rsync の失敗が「**転送元がそもそも無い**」だけかを判定する。run がシナリオ実行の前に
    /// 落ちた場合(リモートのビルド失敗など)、reports/results はリモートに1つも作られないので
    /// 回収は必ず 23 で失敗する —— これを warning にすると、**本当の失敗理由の下に
    /// 無関係な警告が2行積まれる**(2026-08-16 に実機で確認)。
    ///
    /// 判定は exit code だけでは足りない: 23 は「一部が転送できなかった」の総称で、権限や
    /// 途中切断でも返る。**転送元不在のときだけ黙る**ために stderr の文言まで見る
    /// (`change_dir "…" failed: No such file or directory`)
    public static func isMissingSourceFailure(status: Int32, stderr: String) -> Bool {
        guard status == 23 else { return false }
        return stderr.contains("No such file or directory")
    }
}

/// `remoteControl.workspace` の実効ルートがプロジェクトルート配下かどうかで転送経路を分ける
/// (docs/remote-runner.md §17。2026-08-18)。配下(既定 `<project.rootURL>/workspace` を含む)
/// ならプロジェクト転送(`RemoteTransferPlan.rsyncArgs`。`TestProjects/<project>/` を丸ごと運ぶ)が
/// そのまま運ぶので専用の rsync は要らない ―― 同じバイトを二度送らない。配下でない
/// (明示指定でプロジェクト外を指した)ときだけ専用ミラー(`workspaceRsyncArgs`)が要る
public enum WorkspaceRemotePlacement: Equatable, Sendable {
    /// リモート絶対パス = `<RemoteLayout.projectDir(project)>` + (相対パスがあれば "/" + それ)
    case withinProject(remotePath: String)
    case outsideProject
}

public enum WorkspaceRemoteDispatch {

    /// ワークスペースの絶対パスがプロジェクトルート配下かどうかを判定する。パス計算だけの
    /// 純粋関数(I/O なし)。**判定はパス階層のコンポーネント単位で行う** —— 文字列の前方一致
    /// (`hasPrefix`)だと、似た名前の兄弟ディレクトリ("…/E2E-Android-x" が "…/E2E-Android" の
    /// 配下に誤判定される)を弾けない。プロジェクトルートそのものも「配下」(相対パス = 空文字列 →
    /// remotePath はプロジェクトディレクトリそのもの)
    public static func placement(
        workspaceRoot: String, projectRoot: String, layout: RemoteLayout, project: String
    ) -> WorkspaceRemotePlacement {
        guard let relative = relativePath(of: workspaceRoot, under: projectRoot) else {
            return .outsideProject
        }
        let remotePath = relative.isEmpty
            ? layout.projectDir(project)
            : layout.projectDir(project) + "/" + relative
        return .withinProject(remotePath: remotePath)
    }

    /// child が base 自身、または base 配下にあるときだけ相対パス(空文字列 = base 自身)を返す。
    /// nil = 配下でない。両辺とも standardizedFileURL のパスコンポーネントで比較する
    /// (".." や連続スラッシュを畳んでから比較する ―― 生文字列の前方一致だと畳み込み前の表記差で
    /// 誤判定する)
    static func relativePath(of child: String, under base: String) -> String? {
        let childComponents = normalizedComponents(child)
        let baseComponents = normalizedComponents(base)
        guard childComponents.count >= baseComponents.count,
              Array(childComponents.prefix(baseComponents.count)) == baseComponents else {
            return nil
        }
        return childComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private static func normalizedComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents.filter { $0 != "/" }
    }
}

public enum RemoteArtifactsMode: String, Sendable, CaseIterable {
    case collect
    case onDemand = "on-demand"

    public static func parse(_ raw: String) throws -> RemoteArtifactsMode {
        guard let mode = RemoteArtifactsMode(rawValue: raw) else {
            throw RemoteDispatchError.invalidArtifactsMode(
                "must be one of collect, on-demand: \"\(raw)\"")
        }
        return mode
    }
}

public enum RemoteDispatchGate {

    /// `--host` が付いていても**リモートへ送らない**場合がある。
    ///
    /// `--dry-run` はデバイスにも FM にも触れず、判定(セレクタ構文・到達しない scene・
    /// アサーションの無い expectation)は**ローカルのシナリオ原本だけから決まる**
    /// —— リモートへ渡す原本もローカルから転送したものなので、送っても答えは同じで
    /// SSH と転送のぶん遅いだけ。`RunScenarios` が `--dry-run` で `--profile` を
    /// 無視する(拒否ではなく注記して続行する)のと同じ扱いにする。
    ///
    /// **順序の罠**: `run()` のリモート送出は dryRun の分岐より手前にあるので、この門を
    /// 通さないと `--dry-run --host` が**デバイスに触らないつもりで実デバイス実行になる**
    /// (`--dry-run` は中継の許可リストにも載っていないため、リモートは本番実行する)
    public static func dispatchesRemotely(host: String?, dryRun: Bool) -> Bool {
        host != nil && !dryRun
    }
}

/// `--host` が明示指定か、実行プロファイルのマシン `host` 経由の自動ディスパッチかを表す
/// (欠陥1・2026-08-17)。ローカル専用フラグとの併用可否・拒否理由の文言はこれで分岐する
/// (RemoteDispatchFlagPolicy 参照)。machine/host は自動ディスパッチのときの文言合成専用
public enum RemoteDispatchOrigin: Equatable, Sendable {
    case explicitHost
    case autoDispatch(machine: String, host: String)
}

/// `--host`(明示または自動)と併用できないローカル専用フラグの扱い。origin で「拒否」と
/// 「注記して無視」を分ける純粋ロジック(呼び出し側の if に判定を散らさない)
public enum RemoteDispatchFlagPolicy {
    public enum Decision: Equatable {
        case allowed
        /// 実行は続けるが、フラグが効かなかったことを1行伝える(黙って無視しない)
        case ignoredWithNote(String)
        case rejected(String)
    }

    /// `--skip-build`: リモートは常に自前でビルドするため、ローカルのビルド抑止指定はそもそも
    /// 意味を持たない。**自動ディスパッチでは黙って無視する**(拡張の `buildBeforeRun: false` は
    /// 常に `--skip-build` を送るため、host を持つマシンで実行すると利用者が打っていないフラグを
    /// 理由に必ず落ちていた)。`--host` 明示は従来どおり拒否のまま(利用者が意識して付けたフラグ
    /// なので、効かないことを黙認せず気づかせる)
    public static func skipBuild(origin: RemoteDispatchOrigin) -> Decision {
        switch origin {
        case .explicitHost:
            return .rejected("--skip-build is not supported with --host")
        case .autoDispatch:
            return .ignoredWithNote(
                "note: --skip-build is ignored (the remote always builds itself before running)")
        }
    }

    /// `--force-lock`(dispatch.lock を奪う)を受け付けてよいか。**リモートへ行きうる指定が
    /// 1つでもあれば受け付ける** —— `--host` / `--fleet` だけを条件にすると、
    /// **マシンプロファイル経由で自動ディスパッチする実行プロファイル**(`--host` を打たない)や
    /// **デバイスが複数の機械にまたがるプロファイル**(ホスト別の子へ分かれる)で使えず、
    /// 中断した run が残したロックを解除する手段が `remote clean`(デバイスも止まる)か
    /// 手動削除しか無くなる(2026-08-18 に実際に詰まった。子への転送自体は
    /// DeviceMachineRunner/FleetRunner が既に行っている)。
    /// 純粋にローカルだけの実行(プロファイルすら無い)のときだけ、打ち間違いとして拒否する
    public static func forceLockRejection(host: String?, fleet: String?, profile: String?) -> String? {
        let hasRemoteRoute = host != nil || fleet != nil || profile != nil
        guard !hasRemoteRoute else { return nil }
        return "--force-lock requires a run profile, --host or --fleet"
            + " (it releases the dispatch lock on a remote host)"
    }

    /// `--wait-lock`(dispatch.lock の解放をポーリングして待つ)を受け付けてよいか。
    /// forceLockRejection と同じ理由・同じ判定(リモートへ行きうる指定が1つでもあれば受ける)
    public static func waitLockRejection(host: String?, fleet: String?, profile: String?) -> String? {
        let hasRemoteRoute = host != nil || fleet != nil || profile != nil
        guard !hasRemoteRoute else { return nil }
        return "--wait-lock requires a run profile, --host or --fleet"
            + " (it waits for the dispatch lock on a remote host)"
    }

    /// --wait-lock(待つ)と --force-lock(奪う)は同時指定できない(意味が矛盾する)
    public static func waitLockConflictsWithForceLock(forceLock: Bool, waitLock: Int?) -> String? {
        guard forceLock, waitLock != nil else { return nil }
        return "--wait-lock and --force-lock cannot be used together"
    }

    /// `--report-dir` / `--failed` / `--ports`: どちらの origin でも拒否する(意味を持たせられない
    /// のは skipBuild と違い自動側でも変わらない)。文言だけ origin で変える —— 自動ディスパッチの
    /// 拒否理由を「--host と併用できない」のままにすると、利用者は打ってもいない `--host` を
    /// 疑うことになる
    public static func rejected(flag: String, origin: RemoteDispatchOrigin) -> Decision {
        switch origin {
        case .explicitHost:
            return .rejected("\(flag) is not supported with --host")
        case .autoDispatch(let machine, let host):
            return .rejected("\(flag) cannot be used: this profile automatically dispatches to"
                + " machine \"\(machine)\"'s host \"\(host)\" — pass --host local to run it here instead")
        }
    }
}

/// `--wait-lock` のポーリング判断(純粋関数。ssh 発行・Thread.sleep は RemoteRunDispatcher 側)
public enum WaitLockPolling {
    /// ロック保持は分単位の run なので、待ち全体に対する上乗せは高々1間隔。
    /// 1回の試行は ssh 1本で安い
    public static let pollIntervalSeconds = 10
    /// 経過ログの間引き間隔。pollIntervalSeconds の倍数であること(でないと elapsed が
    /// ちょうど割り切れる瞬間が来ず、経過ログが一度も出ない)
    public static let progressIntervalSeconds = 60

    public enum Decision: Equatable {
        case retry
        case giveUp
    }

    /// elapsedSeconds は次の試行**前**の既経過時間(まだ0回待っていなければ0)
    public static func decide(elapsedSeconds: Int, limitSeconds: Int) -> Decision {
        elapsedSeconds < limitSeconds ? .retry : .giveUp
    }

    /// 経過ログを出すか。elapsedSeconds==0(初回試行時点)は常に true
    public static func shouldLogProgress(elapsedSeconds: Int) -> Bool {
        elapsedSeconds == 0 || elapsedSeconds % progressIntervalSeconds == 0
    }
}

public enum RemoteRunArgs {

    /// リモートで実行する `fleetest run` の引数列("fleetest" 自体は含まない)。reportDir は
    /// ディスパッチ単位の隔離先(non-nil のときのみ付与。RemoteRunDispatcher が常に渡す)
    public static func build(project: String, profile: String,
                             scenarios: [String], folders: [String],
                             deviceNames: [String] = [], deviceMachine: String? = nil,
                             heal: Bool, noHeal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                             fastInput: Bool, enableAnimations: Bool, performanceMode: Bool,
                             broadcast: Bool = false,
                             remoteJUnitPath: String?,
                             reportDir: String?, workspace: String? = nil,
                             runGroup: String? = nil) -> [String] {
        // **リモート側は必ず「ここで走らせる」**(--host local)。省略すると、向こうの fleetest が
        // 転送されたマシンプロファイルの host(= 自分のはずのホスト名)を読んで**もう一度
        // ディスパッチしようとする** —— 登録簿に無ければ「未登録のホスト」で落ち、あれば
        // 自分自身へ ssh する。"local" は MachineDispatch.resolve が明示指定として止める
        // (FleetRunner が "local" エントリに --host local を渡すのと同じ理由)
        var args = ["run", "--project", project, "--profile", profile, "--quiet", "--host", "local"]
        if let reportDir { args += ["--report-dir", reportDir] }
        // **デバイスの絞り込みは中継しないと効かない** —— 向こうは同じマシンプロファイルを
        // 受け取るので、渡さないと**全ホストぶんの台**を自分のものとして解決しようとする
        // (同名は別の機械にも居るのが通常。2026-08-17 に実走で確認)。
        // **値は常に "local"** —— 転送したプロファイルは RunnerProfileTransfer が
        // 「そのランナーから見た姿」へ畳んであり、向こうの台は local になっている。
        // ローカルエイリアス(M1Ultra 等)は発行側だけの概念なのでリモートへ出さない
        // (用語の定義は FTCore.RunnerProfileView。2026-08-26 ユーザー決定)
        if !deviceNames.isEmpty { args += ["--device"] + deviceNames }
        if deviceMachine != nil { args += ["--device-machine", DeviceMachineGrouping.localDisplayName] }
        // **remoteControl.workspace が宣言されているプロファイルだけ渡る**(RemoteRunDispatcher が
        // ミラー後に埋める)。渡さないと子は自分のリポジトリルート基準で appPath を解決し、
        // ミラーしていない絶対パスを見に行く(この機能の動機になった不具合そのもの)
        if let workspace { args += ["--workspace", workspace] }
        for scenario in scenarios { args += ["--scenario", scenario] }
        for folder in folders { args += ["--folder", folder] }
        if heal { args.append("--heal") }
        // `--heal` だけ中継すると、ヒールを止めたつもりでリモートはプロファイルの既定で走る
        // (`ProfileRunner.healOverride` は nil = 既定・false = 明示 OFF を区別する)
        if noHeal { args.append("--no-heal") }
        if noLPT { args.append("--no-lpt") }
        if let lptHistoryRuns { args += ["--lpt-history-runs", String(lptHistoryRuns)] }
        if fastInput { args.append("--fast-input") }
        // 実行の意図を変えるフラグは**中継しないと黙って無視される**(リモート側は
        // プロファイルの既定で走る)。ここに載っていない run のフラグは、
        // dispatchToRemoteHost が ValidationError で明示的に拒否している
        if enableAnimations { args.append("--enable-animations") }
        if performanceMode { args.append("--performance") }
        // 中継しないとリモートは共有キューで走る = 「全台で1回ずつ」が黙って「分配」に化ける
        if broadcast { args.append("--broadcast") }
        if let remoteJUnitPath { args += ["--junit", remoteJUnitPath] }
        // 束ね鍵は**中継しないと向こうの run.json に載らない** = リモートで撮った録画だけが
        // 束から外れる(RunMetaRecord.runGroup の宣言)
        if let runGroup { args += ["--run-group", runGroup] }
        return args
    }

    /// リモートで実行する `fleetest api run` の引数列("fleetest" 自体は含まない)。JUnit は
    /// 扱わない(拡張連携は NDJSON 中継のみで完結する)
    /// `api run` に `--enable-animations` は無い(アニメーションは実行プロファイルの
    /// enableAnimations と環境変数から解決する)ので、中継するのは `--performance` だけ
    public static func buildApi(project: String, profile: String, scenarios: [String],
                                deviceNames: [String] = [], deviceMachine: String? = nil,
                                heal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                                performanceMode: Bool,
                                defaultTimeout: Double?, scenarioTimeout: Double?,
                                reportDir: String?, workspace: String? = nil,
                                runGroup: String? = nil) -> [String] {
        // --host local の理由は build() のコメント(リモートでの再ディスパッチを止める)
        var args = ["api", "run", "--project", project, "--profile", profile, "--host", "local"]
        if let reportDir { args += ["--report-dir", reportDir] }
        // **デバイスの絞り込みは中継しないと効かない**(build() と同じ理由。ApiRunMachineFanout が
        // 複数機械にまたがるプロファイルをホストごとの子へ分けるようになったため、`api run --host`
        // でも同名デバイスが別の機械に居りうる。2026-08-17)。値が "local" 固定なのも build() と同じ
        if !deviceNames.isEmpty { args += ["--device"] + deviceNames }
        if deviceMachine != nil { args += ["--device-machine", DeviceMachineGrouping.localDisplayName] }
        // 渡す条件・理由は build() の --workspace と同じ
        if let workspace { args += ["--workspace", workspace] }
        for scenario in scenarios { args += ["--scenario", scenario] }
        if heal { args.append("--heal") }
        if noLPT { args.append("--no-lpt") }
        if let lptHistoryRuns { args += ["--lpt-history-runs", String(lptHistoryRuns)] }
        if performanceMode { args.append("--performance") }
        if let defaultTimeout { args += ["--default-timeout", formatTimeout(defaultTimeout)] }
        if let scenarioTimeout { args += ["--scenario-timeout", formatTimeout(scenarioTimeout)] }
        // 中継の理由は build() の --run-group と同じ
        if let runGroup { args += ["--run-group", runGroup] }
        return args
    }

    /// 整数値は "5"(小数点無し)で渡す — `ApiRunCommand.scenarioTimeout` はリモート側で
    /// Int 型のため "5.0" だと ArgumentParser のパースが失敗する。小数は素通し
    /// (`--default-timeout` は Double 型で問題ない)
    private static func formatTimeout(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

public enum RemoteTimeout {

    /// 明示指定 > 自動算出 > **無期限**。自動算出は「1シナリオあたりの上限 × シナリオ数 +
    /// 固定オーバーヘッド」で minimum..maximum にクランプする(遅いデバイス起動・LPT 待ちを
    /// 1シナリオ600秒/固定900秒で見込む。根拠は docs/remote-runner.md §16.2)。
    ///
    /// **戻り値 nil = タイムアウトを掛けない**(欠陥2・2026-08-17)。`scenarioCount` は呼び出し側の
    /// 明示 `--scenario` の個数で、プロファイル全体や `--fleet` では実行本数を実行前に知らない
    /// ため 0 になる。以前は 0 を「見積り不能」ではなく「overhead だけの極小値」として扱い
    /// minimum(1800秒)へ丸めていたため、30分を超える正当な run が SIGKILL されていた。
    /// タイムアウトは「無限に待たない」ための安全弁であって、正当な実行を打ち切る装置ではない
    /// —— 見積りが立たないときは安全弁を掛けない方が実害が小さい。呼び手が上限を望むなら
    /// `--remote-timeout` で明示すればよい(explicit は従来どおり必ず勝つ)
    public static func seconds(explicit: Int?, scenarioCount: Int, perScenario: Int = 600,
                               overhead: Int = 900, minimum: Int = 1800, maximum: Int = 86_400) -> Int? {
        if let explicit {
            return explicit < 1 ? minimum : explicit
        }
        guard scenarioCount > 0 else { return nil }
        let auto = overhead + perScenario * scenarioCount
        return min(max(auto, minimum), maximum)
    }
}

/// リモートの Aqua セッション(コンソールにログイン中のユーザー)。resolveLayout の $HOME 取得と
/// 同じ ssh 往復に相乗りして取得する(§16.3)。ログインウィンドウで停止中は誰も操作できず
/// run が確実に固まるため、ディスパッチ前に fail fast する
public struct RemoteSessionInfo: Equatable, Sendable {
    public let home: String
    public let consoleUser: String
    public let sshUser: String
    /// プローブが同じ ssh 往復で追加取得した CPU 情報(RemoteProbe.parseSessionInfo の5行形のみ)。
    /// 3行形の出力からは取れないので nil
    public let processorModel: String?
    public let coreCount: Int?

    /// 新フィールドは既定値 nil ―― 既存の3引数呼び出し(セッション情報だけの構築)を壊さない
    public init(home: String, consoleUser: String, sshUser: String,
               processorModel: String? = nil, coreCount: Int? = nil) {
        self.home = home
        self.consoleUser = consoleUser
        self.sshUser = sshUser
        self.processorModel = processorModel
        self.coreCount = coreCount
    }

    /// 大文字小文字は区別する(macOS のユーザー名はケースセンシティブではないが、
    /// ここでは stat/id の生出力をそのまま突き合わせるだけに留める)
    public var isLoggedIn: Bool { consoleUser == sshUser }
}

public enum RemoteProbe {

    /// セッション行(`parseSessionInfo` の2行目)を採る唯一の定義元。**3つの呼び出し元
    /// (RemoteStatusProbe.command / RemoteRunDispatcher.resolveLayout / RemoteSetupCommand の
    /// remoteReach)は必ずこれを使う** —— 片方だけ変えるとホストごとに判定が食い違う。
    ///
    /// `stat -f%Su /dev/console` だけでは**画面共有(仮想ディスプレイ)でログインした機械を
    /// 偽陰性で弾く**: 物理コンソールの所有者は root のまま残るが、ssh ユーザーには
    /// Aqua セッションがあり simctl も xcodebuild も動く(2026-09-01 に M1Ultra で実測。
    /// who / scutil ConsoleUser / Dock はどれも wave1008 を指していた)。
    /// そこで**先に「ssh ユーザー自身の Aqua ドメインが在るか」を直接聞く**。
    /// `launchctl print gui/<uid>` はログインセッションが作るドメインなので、
    /// loginwindow で停止中は存在しない(負の対照: gui/0・gui/999 はどちらも失敗する)。
    /// 無ければ従来の `/dev/console` へ落ちる = 判定が緩むのは実際に GUI セッションが
    /// 在るときだけ。**出力はどちらの枝もちょうど1行**(行数で形を判定しているため)
    public static let consoleUserCommand =
        "if launchctl print gui/$(id -u) >/dev/null 2>&1; then id -un; else stat -f%Su /dev/console; fi"

    /// "echo $HOME; <consoleUserCommand>; id -un" の3行出力(hardware なし)、または
    /// これに "sysctl -n machdep.cpu.brand_string; sysctl -n hw.ncpu" を足した5行出力
    /// (4行目 = CPU モデル・5行目 = コア数)を解析する。末尾の改行1個は許容する。
    /// **先頭3行の妥当性判定は行数によらず同一**(3本ぴったり・いずれも空でない、が前提)。
    /// 行数が3でも5でもなければ nil(古い macOS 等でセッション行が想定外を返す場合を想定。
    /// 呼び出し側は nil を「判定不能」として扱い、ログインチェックだけスキップする)。
    /// 5行形では、4行目が空(トリム後)なら processorModel は nil、5行目が Int にパース
    /// できなければ coreCount は nil(hardware だけ判定不能でもセッション情報は活かす)
    public static func parseSessionInfo(_ output: String) -> RemoteSessionInfo? {

        var lines = output.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 3 || lines.count == 5 else { return nil }
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed[0...2].allSatisfy({ !$0.isEmpty }) else { return nil }
        var processorModel: String?
        var coreCount: Int?
        if trimmed.count == 5 {
            processorModel = trimmed[3].isEmpty ? nil : trimmed[3]
            coreCount = Int(trimmed[4])
        }
        return RemoteSessionInfo(home: trimmed[0], consoleUser: trimmed[1], sshUser: trimmed[2],
                                 processorModel: processorModel, coreCount: coreCount)
    }
}

/// `fleetest remote status`(docs/remote-runner.md §16.5)の1ホスト分の生取得結果。
/// 個々のフィールドは独立にパース失敗し得る(壊れた出力でも取れた分だけ埋める。全体を
/// nil にすると「到達したが1項目読めなかった」場合に他の全項目まで失う)
public struct RemoteHostStatus: Equatable, Sendable {
    public let session: RemoteSessionInfo?
    public let revision: String?
    public let toolchain: String?
    public let binaryPresent: Bool
    public let freeKB: Int?
    /// dispatch.lock の状態(docs/remote-runner.md §18.2 M2)。nil = ブロックが読めず判定不能。
    /// **「今このフリートを誰が使っているか」を手で ssh しに行かずに済ませる**ための欄で、
    /// 破壊的操作(remote clean)の前にも同じ probe を撃つ
    public let lock: RemoteDispatchLock.Probe?

    /// lock は既定 nil ―― 既存の5引数呼び出し(と、それを固定しているテスト)を壊さない
    public init(session: RemoteSessionInfo?, revision: String?, toolchain: String?,
                binaryPresent: Bool, freeKB: Int?, lock: RemoteDispatchLock.Probe? = nil) {
        self.session = session
        self.revision = revision
        self.toolchain = toolchain
        self.binaryPresent = binaryPresent
        self.freeKB = freeKB
        self.lock = lock
    }
}

/// `fleetest remote status` 用の1コマンド組み立て・パース(ssh 1回で全項目を取る。往復を
/// ホスト数×項目数に増やさないための設計 = RemoteCommands.swift が全ホストへ並列に投げる)。
/// **`RemoteShell.quote` は使わない**: layout の base/toolRoot/binary はこのユースケースでは
/// $HOME を未解決のまま埋め込んだ式(RemoteLayout.resolveBase(raw, home: "$HOME"))であり得る
/// ため、二重引用符で包んで実行時にリモートシェルへ展開させる(単一引用符は変数展開そのものを
/// 抑止してしまう)。解決済みの具体パスを渡しても二重引用符は害にならない
public enum RemoteStatusProbe {
    private static let separator = "---FT---"

    public static func command(layout: RemoteLayout) -> String {
        let sep = "echo '\(separator)'"
        let steps = [
            "echo $HOME; \(RemoteProbe.consoleUserCommand); id -un",
            "git -C \(dquote(layout.toolRoot)) rev-parse HEAD 2>/dev/null || echo -",
            "xcodebuild -version",
            "xcrun --sdk iphonesimulator --show-sdk-build-version",
            "test -x \(dquote(layout.binary)) && echo yes || echo no",
            "df -k \(dquote(layout.base)) | tail -1",
            // **dispatch.lock はホストに1本**(発行者ネームスペースの外側)。RemoteDispatchLock の
            // probeCommand と同じ形だが、こちらは $HOME 未解決の base を扱うため dquote で包む
            // (単一引用符だと展開されない。ファイル冒頭の注記と同じ理由)
            "if [ -d \(dquote(RemoteDispatchLock.lockDirPath(base: layout.base))) ]; then echo held;"
                + " cat \(dquote(RemoteDispatchLock.infoFilePath(base: layout.base))) 2>/dev/null || true;"
                + " else echo absent; fi",
        ]
        return steps.joined(separator: "; \(sep); ")
    }

    /// 壊れていてもできる範囲を埋める(全体 nil にしない)。ブロック数が足りない・
    /// セッション3行が壊れている等は該当項目だけ nil/false に落ちる
    public static func parse(_ output: String) -> RemoteHostStatus {
        let blocks = splitBlocks(output)
        func block(_ i: Int) -> String? { blocks.indices.contains(i) ? blocks[i] : nil }

        let session = block(0).flatMap(RemoteProbe.parseSessionInfo)
        let revision = trimmedNonDash(block(1))
        let xcodeVersion = trimmedNonEmpty(block(2))
        let sdkBuild = trimmedNonEmpty(block(3))
        let toolchain = xcodeVersion.flatMap { xcode in
            sdkBuild.map { ToolchainFingerprint.compose(xcodeVersionOutput: xcode, sdkBuild: $0) }
        }
        let binaryPresent = trimmedNonEmpty(block(4)) == "yes"
        let freeKB = block(5).flatMap(parseFreeKB)
        // 旧ランナー(ブロックが6個しか無い)では nil = 判定不能。「ロック無し」に倒さない
        let lock = block(6).flatMap(RemoteDispatchLock.parseProbe)

        return RemoteHostStatus(session: session, revision: revision, toolchain: toolchain,
                                binaryPresent: binaryPresent, freeKB: freeKB, lock: lock)
    }

    /// 二重引用符クォート。`$` はエスケープしない($HOME を展開させるための唯一の理由でこの
    /// 関数を使っている)。`\`/`"`/`` ` `` はエスケープする(--remote-dir にこれらの文字が
    /// 混じっても引用符から抜け出さないようにする最低限の防御。`\` を先にエスケープしないと
    /// 後続のエスケープで二重にエスケープされる)
    public static func dquote(_ s: String) -> String {
        var escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    /// separator 行(前後の空白は無視)で区切る。各ブロックは元の改行を保ったまま結合し直す
    /// (RemoteProbe.parseSessionInfo は3行ぴったりを要求するため、セッション項目のブロックは
    /// 内部改行を保持する必要がある)
    private static func splitBlocks(_ output: String) -> [String] {
        var lines = output.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var blocks: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == separator {
                blocks.append([])
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.map { $0.joined(separator: "\n") }
    }

    private static func trimmedNonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedNonDash(_ s: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(s), trimmed != "-" else { return nil }
        return trimmed
    }

    /// `df -k` の最終行(ヘッダ抜き)から Available(4列目)を KB で取る。列数不足・非数値は nil
    public static func parseFreeKB(_ line: String) -> Int? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 4 else { return nil }
        return Int(fields[3])
    }
}

/// `fleetest remote clean`(docs/remote-runner.md §16.4)の削除対象・削除コマンド。
/// dispatch(実行中に残った孤児)/ 各プロジェクトの reports・results の3系統を対象にする
public enum RemoteCleanPlan {

    /// `--dry-run` でデバイスを止めてよいか = **止めてはいけない**。`remote clean` は削除の前に
    /// `devices down`(ブリッジ停止 + シミュレータ/エミュレータのシャットダウン)を撃つが、これは
    /// **走っている run を巻き添えにする破壊的操作**で、「消える物を見るだけ」の dry-run が
    /// 実際に環境を壊すのは契約違反(2026-08-16 に実機で踏んだ: プレビューのつもりで
    /// ランナーの 8123/8124 のブリッジが落ちた)
    public static func stopsDevices(dryRun: Bool) -> Bool { !dryRun }

    /// keepDays より古いエントリを消す(dryRun なら列挙するだけの)find コマンド一覧。
    /// **全発行者(`users/*/work`)+ 旧レイアウト(`work`)を横断する**(§18.2) —— ディスクは
    /// ホスト共有資源なので保持ポリシーは全員分に掛ける。旧レイアウトの掃除は移行期のためだけ
    /// (存在しなければ find が対象0件で終わるだけで、呼び出し側の扱いは他のターゲットと同じ)。
    /// グロブ部分はシェル展開に任せる(呼び出し側は単一プロジェクト/発行者へ絞り込まない)ため、
    /// `base` 部分だけ `RemoteShell.quote` しグロブ部分は非クォートのまま連結する(引用符の直後に
    /// 続く非クォート文字列はシェル上で1語に結合される。丸ごとクォートするとグロブが展開されない)
    public static func commands(layout: RemoteLayout, keepDays: Int, dryRun: Bool) -> [String] {
        let action = dryRun ? "-print" : "-exec rm -rf {} +"
        let base = RemoteShell.quote(layout.base)
        let projects = RemoteLayout.projectsDirName
        let targets = [
            // 配信の控え(FTCore.StreamLease)。**ホスト共有の1箇所**で、書いた側は execv で
            // 化けるので自分では消せない —— 死んだ pid の控えが溜まる(読む側は無視するが、
            // **pid が一巡して別プロセスに当たると、その台の配信が誰にも張れなくなる**)。
            // ここで保持ポリシーに掛けて上限を作る(数日前の配信は必ず終わっている)
            base + "/.fleetest/streams",
            base + "/users/*/work/.fleetest/dispatch",
            base + "/users/*/work/\(projects)/*/reports",
            base + "/users/*/work/\(projects)/*/results",
            base + "/work/.fleetest/dispatch",
            base + "/work/\(projects)/*/reports",
            base + "/work/\(projects)/*/results",
        ]
        return targets.map { "find \($0) -mindepth 1 -maxdepth 1 -mtime +\(keepDays) \(action)" }
    }
}

/// `du -sk <base>/users/*/work <base>/work` の出力 → 発行者ごとの使用量(純粋)。
/// **ディスクはホスト共有資源**なので「誰のぶんか」が見えないと消す判断ができない(§18.1)。
/// 行の形は `<KB>\t<path>`(BSD du)。想定外の行は捨てる = 壊れた1行で全体を失わない
public enum RemoteDiskUsage {
    public struct Row: Equatable, Sendable {
        public let issuer: String
        public let kb: Int
        public init(issuer: String, kb: Int) {
            self.issuer = issuer
            self.kb = kb
        }
    }

    /// 旧レイアウト(`<base>/work`)の表示名。発行者ネームスペース化前の残骸で、
    /// 誰のものとも言えないので発行者名の代わりにこの語を出す
    public static let legacyLabel = "(legacy work)"

    public static func parse(_ output: String, usersDir: String, base: String) -> [Row] {
        let legacyPath = stripTrailingSlashes(base) + "/work"
        let prefix = stripTrailingSlashes(usersDir) + "/"
        var rows: [Row] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let kb = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            if path == legacyPath {
                rows.append(Row(issuer: legacyLabel, kb: kb))
            } else if path.hasPrefix(prefix), path.hasSuffix("/work") {
                let issuer = String(path.dropFirst(prefix.count).dropLast("/work".count))
                guard !issuer.isEmpty, !issuer.contains("/") else { continue }
                rows.append(Row(issuer: issuer, kb: kb))
            }
        }
        // 大きい順(消す判断に使う欄なので、目に入る順を「食っている順」にする)
        return rows.sorted { $0.kb > $1.kb }
    }

    private static func stripTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

public enum RemoteShell {

    /// POSIX sh 用シングルクォート。空文字は `''`(引数の個数を保つため。クォート無しで
    /// 落とすと後続引数がずれる)
    public static func quote(_ s: String) -> String {
        guard !s.isEmpty else { return "''" }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// リモートで実行する1本の sh コマンド。cwd = layout.workDir(受け手パッケージ)、バイナリは
    /// layout.toolRoot 配下の絶対パス(相対 `./.build/...` は cwd が work のため使えない)。
    /// バイナリ不在は exit 90(RemoteRunDispatcher がこの値だけ「ビルドしてください」の専用
    /// メッセージに変える)。project sync は失敗を黙認する(`|| true`) — 失敗しても実体は
    /// 後続の run が明確に失敗するので、ここで止めると本来の失敗理由が sync の方に隠れる。
    /// SSH の Background セッションのまま直接実行する(ユーザーの launchd ドメインへ昇格させる
    /// 処理は挟まない)。コンソールにログインしている限りそのままで launchd ドメイン
    /// (CoreSimulator 等)へ到達できる(2026-07-31 実測)
    /// `fmConcurrency` は登録簿の欄(`RemoteHostEntry`)。**機械によっては FM を 2 並列以上で
    /// 呼ぶと壊れる**(実測と経緯は docs/remote-runner.md)ので、枠を機械ごとに絞れるようにする。
    /// nil のときは**1バイトも足さない** —— ランナー側の既定(`FMLock.defaultConcurrency`)に任せる
    public static func remoteRunCommand(layout: RemoteLayout, fleetestArgs: [String],
                                        issuer: String? = nil,
                                        fmConcurrency: Int? = nil) -> String {
        let binary = quote(layout.binary)
        let guardCmd = "test -x \(binary) || { echo \"fleetest binary not found on remote"
            + " — run: swift build --product fleetest\" >&2; exit 90; }"
        let syncCmd = "\(binary) project sync >/dev/null 2>&1 || true"
        let args = fleetestArgs.map(quote).joined(separator: " ")
        let launch = "\(binary) \(args)"
        // 非対話 ssh の PATH は /usr/bin:/bin:/usr/sbin:/sbin だけで Homebrew が入らない。
        // xcodegen(iOS ワーカーのビルドに必須)・adb などが見えず「No such file or directory」で
        // 落ちる(2026-07-31 の localhost E2E で実測)。ログインシェルに頼ると受け手の
        // シェル設定に依存するので、ここで明示的に足す
        let pathCmd = "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\""
        // 発行者はディスパッチ側から運ぶ(LocalConfig.resolveIssuerId が FT_ISSUER を最優先で
        // 読む契約)。ランナー機側で解決させると全員が共有アカウントの同じ値になる
        let issuerCmd = issuer.map { "export FT_ISSUER=\(quote($0)) && " } ?? ""
        let fmCmd = fmConcurrency.map { "export FT_FM_CONCURRENCY=\(quote(String($0))) && " } ?? ""
        return "cd \(quote(layout.workDir)) 2>/dev/null && test -f Package.swift || "
            + "{ echo \"no runner workspace at \(layout.workDir) — run: fleetest remote setup"
            + " <this host> once for this issuer (docs/remote-runner.md §18)\" >&2; exit 91; } && "
            + "\(pathCmd) && \(runnerBaseCmd(layout: layout))\(issuerCmd)\(fmCmd)\(guardCmd) && \(syncCmd) && \(launch)"
    }

    /// `fleetest remote exec`(docs/remote-runner.md §14「単発コマンドの転送は汎用化する」)。
    /// remoteRunCommand と同じ PATH 補正・バイナリ不在 exit 90・workspace 不在 exit 91 の規律を
    /// 踏襲するが、**project sync は撃たない** — 照会・単発操作が目的で、同期は run 専用の前処理だから
    public static func remoteExecCommand(layout: RemoteLayout, args: [String]) -> String {
        let binary = quote(layout.binary)
        let guardCmd = "test -x \(binary) || { echo \"fleetest binary not found on remote"
            + " — run: swift build --product fleetest\" >&2; exit 90; }"
        let quotedArgs = args.map(quote).joined(separator: " ")
        let launch = "\(binary) \(quotedArgs)"
        let pathCmd = "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\""
        // **exec も発行者を運ぶ**(run と同じ理由)。exec が入るのは `users/<layout.issuer>/work`
        // なので、そのネームスペースの持ち主がそのまま帰属になる。fan-out の子(api monitor /
        // api device-stream)はこの値で「ロックを握っているのは自分か」を判定する(HostOccupancy)
        let issuerCmd = "export FT_ISSUER=\(quote(layout.issuer)) && "
        return "cd \(quote(layout.workDir)) 2>/dev/null && test -f Package.swift || "
            + "{ echo \"no runner workspace at \(layout.workDir) — run: fleetest remote setup"
            + " <this host> once for this issuer (docs/remote-runner.md §18)\" >&2; exit 91; } && "
            + "\(pathCmd) && \(runnerBaseCmd(layout: layout))\(issuerCmd)\(guardCmd) && \(launch)"
    }

    /// ランナー機の base を子へ渡す(FTCore.RunnerBase)。**手元実行では存在しない値**なので、
    /// 子はこの有無で「ランナー機の上に居るか」を判定でき、dispatch.lock を ssh 無しで読める
    /// (docs/remote-runner.md §18.2)。run/exec の両方に置く —— 片方だけだと、その経路の子だけ
    /// 占有が見えないまま配信を張り続ける
    private static func runnerBaseCmd(layout: RemoteLayout) -> String {
        "export \(RunnerBase.environmentKey)=\(quote(layout.base)) && "
    }
}

public enum RemoteReportLink {

    /// 回収済みレポートへの貼り直し。リモートの run が記録する `reportPath` は
    /// **ディスパッチ単位の隔離先**(`.fleetest/dispatch/<stamp>/reports/…`)を指すが、そこは
    /// 回収後に削除される(`RemoteRunDispatcher.cleanupDispatchDir`)。回収先はローカルの
    /// `TestProjects/<project>/reports/` で、**ファイル名は rsync がそのまま保つ**ので、
    /// 記録側を回収先へ向け直せば results から辿れるようになる。
    ///
    /// これを入れないと**リモート実行の結果だけレポートへ飛べない**(results には載るのに
    /// リンクがどこも指していない。2026-08-16 に実機で確認)。ローカル実行は最初から
    /// リポジトリルート基準の `TestProjects/<project>/reports/<file>` を記録している
    /// ので、書き換え後は両者が同じ規約になる。
    ///
    /// このディスパッチの stamp を含むものだけ書き換える(他の run の記録に触らない)。
    /// 対象外なら nil。
    public static func rewrittenReportPath(
        recorded: String, stamp: String, projectReportsPathFromRepoRoot: String
    ) -> String? {
        let marker = ".fleetest/dispatch/\(stamp)/reports/"
        guard let range = recorded.range(of: marker) else { return nil }
        let fileName = String(recorded[range.upperBound...])
        guard !fileName.isEmpty, !fileName.contains("/") else { return nil }
        return projectReportsPathFromRepoRoot + "/" + fileName
    }
}

public enum RemotePathRewrite {

    /// テキスト(JUnit XML / NDJSON 行)内の remoteRoot(絶対パス)を localRoot へ全置換する。
    /// JUnit の `report:`/`worker:` 行、NDJSON の `reportPath` 等はリモートの絶対パスのまま
    /// 書かれるため、回収・中継後にここで手元パスへ書き換える。末尾 "/" の有無は同一視する
    /// (rsync 側の契約と揃える)。
    ///
    /// **渡す remoteRoot は `layout.workDir`**(`base` ではない)—— 手元のリポジトリルートに
    /// 対応するのは受け手パッケージ = workDir で、base はその2段上。base を渡すと
    /// `users/<issuer>/work` が残り、**手元に存在しないパス**が画面と記録に出る
    /// (2026-08-26 の実害: リモート実行のログが `<手元のクローン>/users/<issuer>/work/…` を指し、
    /// 実際に走ったスクリプトと違うパスに見えて原因調査が空転した)
    public static func rewrite(_ text: String, remoteRoot: String, localRoot: String) -> String {
        let remote = stripTrailingSlash(remoteRoot)
        guard !remote.isEmpty else { return text }
        return text.replacingOccurrences(of: remote, with: stripTrailingSlash(localRoot))
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        var result = path
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// チャンク境界が行の途中に来る ssh stdout ストリームを行単位に組み立て直す。feed が返すのは
/// 「完成した行」だけ(末尾の未完行は次の feed まで内部に保持)。flush は run 終了後の残りを返す
public final class StreamLineSplitter {
    private var buffer = Data()

    public init() {}

    public func feed(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = buffer[buffer.startIndex..<newlineIndex]
            if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }

    /// 末尾 CR も落とす: `-tt` 経由のリモート実行(§16.1)は行末以外に CR を混ぜないが、
    /// 子プロセスが改行前に kill されると「CR だけ来て \n が来ない」未完行が buffer に残り得るため
    public func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        var data = buffer
        if data.last == UInt8(ascii: "\r") { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum RemoteRelay {

    /// 中継行が NDJSON(機械可読)か否か。`ssh -tt` は擬似 TTY のため**リモートの stderr が
    /// stdout に合流する**ので、apiRun ではこれで振り分けないと NDJSON 契約(stdout は
    /// 1行1イベント)が壊れる。イベントは必ず JSON オブジェクトなので `{` 始まりで判定する
    public static func isMachineReadableLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("{")
    }
}
