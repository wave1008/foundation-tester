// RemoteDispatch.swift
// `ftester run --host` (docs/remote-runner.md §3・§7・Phase 1) の純粋ロジック。
// プロセス起動・ネットワーク I/O はここに置かない(呼び出し側 = Sources/ftester/RemoteRunDispatcher.swift)。

import Foundation

public enum RemoteDispatchError: Error, LocalizedError {
    case invalidHost(String)
    case invalidRemoteDir(String)
    case invalidArtifactsMode(String)
    case incompatible([String])
    case remoteSetupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost(let detail):
            return "invalid --host: \(detail)"
        case .invalidRemoteDir(let detail):
            return "invalid --remote-dir: \(detail)"
        case .invalidArtifactsMode(let detail):
            return "invalid --remote-artifacts: \(detail)"
        case .incompatible(let reasons):
            return (["remote host is not compatible:"] + reasons.map { "  - \($0)" })
                .joined(separator: "\n")
        case .remoteSetupFailed(let detail):
            return "remote setup failed: \(detail)"
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

public enum RemoteCompat {

    /// fail-closed: 片方でも取得できなければ(nil)不一致に含める(古い/未検証の組で
    /// 黙って走らせない。CLAUDE.md「片方だけ変えない」規律をマシン間に広げる)
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
/// (受け手パッケージ。Projects・results・.build)。マシンが既に持つローカルインストール
/// (受け手自身の `~/foundation-tester` 等)とは別物にすることで、rsync --delete による
/// ユーザー資産の消失・SPM ビルドロック競合・results DB 混在を避ける
public struct RemoteLayout: Equatable, Sendable {
    public let base: String

    public init(base: String) {
        self.base = Self.stripTrailingSlash(base)
    }

    /// **ディレクトリ名は "foundation-tester" 固定**(短くしない)。SPM はパス依存の
    /// パッケージ名をディレクトリ名から導出するため、受け手 Package.swift が宣言する
    /// `package: "foundation-tester"` と一致しないと "unknown package" でマニフェストが
    /// 壊れる(2026-07-31 の localhost E2E で実測)。install.sh の既定
    /// TOOL_ROOT(= WORK_DIR/../foundation-tester)とも揃う
    public var toolRoot: String { base + "/foundation-tester" }
    public var workDir: String { base + "/work" }
    public var binary: String { toolRoot + "/.build/debug/ftester" }

    public func projectDir(_ project: String) -> String {
        workDir + "/Projects/" + project
    }

    /// ディスパッチ1回分の隔離先(reports のみ。回収後にリモート側で削除する
    /// = RemoteRunDispatcher.cleanupDispatchDir)。stamp は呼び出し側が一意に払い出す
    public func dispatchReportDir(stamp: String) -> String {
        workDir + "/.ftester/dispatch/" + stamp + "/reports"
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

    /// `--remote-dir` の生値(既定 "~/ftester-runner")を絶対パスへ解決する。チルダはリモートの
    /// シェルが展開するものであり、ここではローカルで文字列として畳み込む(ssh 越しの `$HOME`
    /// 展開に頼るとコマンド合成が複雑になるため、呼び出し側が事前に1回 `echo $HOME` で取得した
    /// 値をここに渡す)。空/空白のみは既定値にフォールバックする
    public static func resolveBase(_ raw: String, home: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "~/ftester-runner" : trimmed
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

    /// rsync 引数(実行ファイル名は含まない)。順序・末尾スラッシュの有無は rsync の
    /// ディレクトリ同一視の契約なので厳守する。reports/results/.ftester は成果物側
    /// (実行のたびにリモートで再生成される・回収は別経路)なので除外する
    public static func rsyncArgs(project: String, localProjectsDir: String,
                                 layout: RemoteLayout, sshTarget: String) -> [String] {
        [
            "-az", "--delete",
            "--exclude", "/reports", "--exclude", "/results", "--exclude", "/.ftester",
            "\(localProjectsDir)/\(project)/",
            "\(sshTarget):\(layout.projectDir(project))/",
        ]
    }
}

public enum RemoteArtifactCollection {

    /// results/ 回収(録画+RunRecorder の run.json/scenario json/host-metrics.ndjson)の rsync 引数。
    /// **--delete は付けない**(RemoteTransferPlan.rsyncArgs と違い、ローカルで別に走った run の
    /// results を巻き添えで消してはいけない)。差分のみ転送するので繰り返し呼んでも安い
    public static func resultsRsyncArgs(project: String, layout: RemoteLayout,
                                        sshTarget: String, localProjectsDir: String) -> [String] {
        [
            "-az",
            "\(sshTarget):\(layout.projectDir(project))/results/",
            "\(localProjectsDir)/\(project)/results/",
        ]
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

public enum RemoteRunArgs {

    /// リモートで実行する `ftester run` の引数列("ftester" 自体は含まない)。reportDir は
    /// ディスパッチ単位の隔離先(non-nil のときのみ付与。RemoteRunDispatcher が常に渡す)
    public static func build(project: String, profile: String,
                             scenarios: [String], folders: [String],
                             heal: Bool, noHeal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                             fastInput: Bool, enableAnimations: Bool, performanceMode: Bool,
                             remoteJUnitPath: String?,
                             reportDir: String?) -> [String] {
        var args = ["run", "--project", project, "--profile", profile, "--quiet"]
        if let reportDir { args += ["--report-dir", reportDir] }
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
        if let remoteJUnitPath { args += ["--junit", remoteJUnitPath] }
        return args
    }

    /// リモートで実行する `ftester api run` の引数列("ftester" 自体は含まない)。JUnit は
    /// 扱わない(拡張連携は NDJSON 中継のみで完結する)
    /// `api run` に `--enable-animations` は無い(アニメーションは実行プロファイルの
    /// enableAnimations と環境変数から解決する)ので、中継するのは `--performance` だけ
    public static func buildApi(project: String, profile: String, scenarios: [String],
                                heal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                                performanceMode: Bool,
                                defaultTimeout: Double?, scenarioTimeout: Double?,
                                reportDir: String?) -> [String] {
        var args = ["api", "run", "--project", project, "--profile", profile]
        if let reportDir { args += ["--report-dir", reportDir] }
        for scenario in scenarios { args += ["--scenario", scenario] }
        if heal { args.append("--heal") }
        if noLPT { args.append("--no-lpt") }
        if let lptHistoryRuns { args += ["--lpt-history-runs", String(lptHistoryRuns)] }
        if performanceMode { args.append("--performance") }
        if let defaultTimeout { args += ["--default-timeout", formatTimeout(defaultTimeout)] }
        if let scenarioTimeout { args += ["--scenario-timeout", formatTimeout(scenarioTimeout)] }
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

    /// 明示指定 > 自動算出。自動算出は「1シナリオあたりの上限 × シナリオ数 + 固定オーバーヘッド」で
    /// minimum..maximum にクランプする(遅いデバイス起動・LPT 待ちを1シナリオ600秒/固定900秒で
    /// 見込む。根拠は docs/remote-runner.md §16.2)。scenarioCount 0(全件指定なし)は自動算出が
    /// overhead 分しか積まないため実質 minimum が効く
    public static func seconds(explicit: Int?, scenarioCount: Int, perScenario: Int = 600,
                               overhead: Int = 900, minimum: Int = 1800, maximum: Int = 86_400) -> Int {
        if let explicit {
            return explicit < 1 ? minimum : explicit
        }
        let auto = overhead + perScenario * max(scenarioCount, 0)
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
    /// 大文字小文字は区別する(macOS のユーザー名はケースセンシティブではないが、
    /// ここでは stat/id の生出力をそのまま突き合わせるだけに留める)
    public var isLoggedIn: Bool { consoleUser == sshUser }
}

public enum RemoteProbe {

    /// "echo $HOME; stat -f%Su /dev/console; id -un" の3行出力を解析する。末尾の改行1個は
    /// 許容するが、行が3本ぴったりでない・いずれかの行が空(トリム後)なら nil
    /// (古い macOS 等で `/dev/console` が想定外を返す場合を想定。呼び出し側は nil を
    /// 「判定不能」として扱い、ログインチェックだけスキップする)
    public static func parseSessionInfo(_ output: String) -> RemoteSessionInfo? {
        var lines = output.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 3 else { return nil }
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ !$0.isEmpty }) else { return nil }
        return RemoteSessionInfo(home: trimmed[0], consoleUser: trimmed[1], sshUser: trimmed[2])
    }
}

/// `ftester remote status`(docs/remote-runner.md §16.5)の1ホスト分の生取得結果。
/// 個々のフィールドは独立にパース失敗し得る(壊れた出力でも取れた分だけ埋める。全体を
/// nil にすると「到達したが1項目読めなかった」場合に他の全項目まで失う)
public struct RemoteHostStatus: Equatable, Sendable {
    public let session: RemoteSessionInfo?
    public let revision: String?
    public let toolchain: String?
    public let binaryPresent: Bool
    public let freeKB: Int?
}

/// `ftester remote status` 用の1コマンド組み立て・パース(ssh 1回で全項目を取る。往復を
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
            "echo $HOME; stat -f%Su /dev/console; id -un",
            "git -C \(dquote(layout.toolRoot)) rev-parse HEAD 2>/dev/null || echo -",
            "xcodebuild -version",
            "xcrun --sdk iphonesimulator --show-sdk-build-version",
            "test -x \(dquote(layout.binary)) && echo yes || echo no",
            "df -k \(dquote(layout.base)) | tail -1",
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

        return RemoteHostStatus(session: session, revision: revision, toolchain: toolchain,
                                binaryPresent: binaryPresent, freeKB: freeKB)
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

/// `ftester remote clean`(docs/remote-runner.md §16.4)の削除対象・削除コマンド。
/// dispatch(実行中に残った孤児)/ 各プロジェクトの reports・results の3系統を対象にする
public enum RemoteCleanPlan {

    /// keepDays より古いエントリを消す(dryRun なら列挙するだけの)find コマンド一覧。
    /// `Projects/*/reports`・`Projects/*/results` はシェルのグロブ展開に任せる(呼び出し側は
    /// 単一プロジェクトへ絞り込まない)ため、workDir 部分だけ `RemoteShell.quote` し
    /// グロブ部分は非クォートのまま連結する(引用符の直後に続く非クォート文字列は
    /// シェル上で1語に結合される。丸ごとクォートするとグロブが展開されなくなる)
    public static func commands(layout: RemoteLayout, keepDays: Int, dryRun: Bool) -> [String] {
        let action = dryRun ? "-print" : "-exec rm -rf {} +"
        let base = RemoteShell.quote(layout.workDir)
        let targets = [
            base + "/.ftester/dispatch",
            base + "/Projects/*/reports",
            base + "/Projects/*/results",
        ]
        return targets.map { "find \($0) -mindepth 1 -maxdepth 1 -mtime +\(keepDays) \(action)" }
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
    public static func remoteRunCommand(layout: RemoteLayout, ftesterArgs: [String]) -> String {
        let binary = quote(layout.binary)
        let guardCmd = "test -x \(binary) || { echo \"ftester binary not found on remote"
            + " — run: swift build --product ftester\" >&2; exit 90; }"
        let syncCmd = "\(binary) project sync >/dev/null 2>&1 || true"
        let args = ftesterArgs.map(quote).joined(separator: " ")
        let launch = "\(binary) \(args)"
        // 非対話 ssh の PATH は /usr/bin:/bin:/usr/sbin:/sbin だけで Homebrew が入らない。
        // xcodegen(iOS ワーカーのビルドに必須)・adb などが見えず「No such file or directory」で
        // 落ちる(2026-07-31 の localhost E2E で実測)。ログインシェルに頼ると受け手の
        // シェル設定に依存するので、ここで明示的に足す
        let pathCmd = "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\""
        return "cd \(quote(layout.workDir)) && \(pathCmd) && \(guardCmd) && \(syncCmd) && \(launch)"
    }
}

public enum RemotePathRewrite {

    /// テキスト(JUnit XML / NDJSON 行)内の remoteRoot(絶対パス)を localRoot へ全置換する。
    /// JUnit の `report:`/`worker:` 行、NDJSON の `reportPath` 等はリモートの絶対パスのまま
    /// 書かれるため、回収・中継後にここで手元パスへ書き換える。末尾 "/" の有無は同一視する
    /// (rsync 側の契約と揃える)
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
