// RemoteSetup.swift
// `fleetest remote setup` (docs/remote-runner.md §14) の純粋ロジック。
// scp/ssh の起動・確認プロンプトは Sources/fleetest/RemoteSetupCommand.swift 側(単体テスト対象外)。
// RemoteShell/RemoteLayout/RemoteProbe 等は Sources/FTRemote/RemoteDispatch.swift(同じ規律を踏襲する)。

import Foundation
import FTCore

public enum RemoteSetupError: Error, LocalizedError, Equatable {
    case invalidRevision(String)
    case unsafeUninstallBase(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRevision(let detail):
            return "invalid revision: \(detail)"
        case .unsafeUninstallBase(let detail):
            return "refusing to uninstall: \(detail)"
        }
    }
}

/// `Scripts/preflight.sh --runner` の exit code(docs/remote-runner.md §14「構成」)。
/// ready=0 / needsManual=2 / blocked=1。それ以外は想定外(unknown)として扱う
public enum RemotePreflightVerdict: Equatable, Sendable {
    case ready
    case needsManual
    case blocked
    case unknown(Int32)
}

/// `Scripts/install.sh` の `record()` が使う4状態と同じ語彙(1ステップ1行の逐次表示。
/// docs/remote-runner.md §14「構成」/ CLAUDE.md「画面は各ステップ1行(逐次)」)
public enum RemoteSetupStepStatus: String, Equatable, Sendable {
    case ok, warn, fail, skip
}

/// install.sh の `step_line()`/`status_icon()` と同じ書式("<icon> [<status>] <name>: <detail>")。
/// bash と Swift にまたがるが、受け手が同じ体裁で読めるよう揃える。行頭の `[status]` は
/// 機械可読用(エージェントが warn/fail を拾う。install.sh 側のコメントと同じ理由)
public enum RemoteSetupStepLine {
    public static func render(name: String, status: RemoteSetupStepStatus, detail: String) -> String {
        "\(icon(status)) [\(status.rawValue)] \(name): \(detail)"
    }

    private static func icon(_ status: RemoteSetupStepStatus) -> String {
        switch status {
        case .ok: return "✅"
        case .warn: return "⚠️ "
        case .fail: return "❌"
        case .skip: return "⏭️ "
        }
    }
}

/// 集計行(install.sh の `print_summary` と同じ計上: warn/fail はどちらも「要対応」に数える)
public struct RemoteSetupSummary: Equatable, Sendable {
    public let ok: Int
    public let skip: Int
    public let needsAttention: Int

    public init(statuses: [RemoteSetupStepStatus]) {
        ok = statuses.filter { $0 == .ok }.count
        skip = statuses.filter { $0 == .skip }.count
        needsAttention = statuses.filter { $0 == .warn || $0 == .fail }.count
    }

    public var line: String {
        "✅ done \(ok) / ⏭️ skipped \(skip) / ⚠️ needs attention \(needsAttention)"
    }
}

public enum RemoteSetupPlan {

    /// `Scripts/install.sh` へ渡す引数列(docs/remote-runner.md §14「構成」の並びのまま)。
    /// **`--tool-root` を明示する**(§18.2: work が `<base>/users/<issuer>/work` へ2階層深くなり、
    /// install.sh の既定 `<work-dir>/../foundation-tester` が `RemoteLayout.toolRoot`
    /// (`<base>/foundation-tester`)と一致しなくなったため)
    public static func installArgs(workDir: String, projectName: String, toolRoot: String) -> [String] {
        [
            "--work-dir", workDir,
            "--tool-root", toolRoot,
            "--name", projectName,
            "--skip-extension",
            "--skip-mcp",
            // ランナー機にエージェントの入口は要らない(人が開く機械ではない。
            // AgentIntegration.entryPointFile と対)
            "--skip-claude-md",
            "--no-next-steps",
        ]
    }

    /// `Scripts/preflight.sh` へ渡す引数列。`--work-dir` は §18.2 で work が発行者ごとに分かれた
    /// ため必須(既定の `<base>/work` は見に行かない)
    public static func preflightArgs(base: String, workDir: String) -> [String] {
        ["--runner", "--base", base, "--work-dir", workDir]
    }

    public static func preflightVerdict(exitCode: Int32) -> RemotePreflightVerdict {
        switch exitCode {
        case 0: return .ready
        case 2: return .needsManual
        case 1: return .blocked
        default: return .unknown(exitCode)
        }
    }

    /// install.sh が要求する前提(`[ -d "$WORK_DIR" ]`)を満たすためのコマンド。初回はリモートに
    /// work/ が無いため、scp+実行より前に必ず一度これを通す
    public static func ensureWorkDirCommand(layout: RemoteLayout) -> String {
        "mkdir -p \(RemoteShell.quote(layout.workDir))"
    }

    /// scp 済みのローカルスクリプトをリモートで実行し、終了コードに関わらず一時ファイルを消す。
    /// `$?` を保存してから `rm` し、保存した値で exit する(失敗パスでも一時ファイルを残さない)。
    ///
    /// **保存先を `status` にしない** —— ssh が起こすのは受け手のログインシェルで、macOS の既定は
    /// zsh。zsh では `status` が `$?` の読み取り専用エイリアスなので、代入が
    /// `read-only variable: status` で失敗し、**中のスクリプトの終了コードが zsh のエラーに化けて
    /// 消える**(preflight の needs-manual=2 が 1 に化け blocked と誤報した。rm も実行されず
    /// 一時ファイルが残った。2026-08-16 に localhost で実測)
    /// **PATH に Homebrew を足してから実行する**。非対話 ssh の PATH は
    /// `/usr/bin:/bin:/usr/sbin:/sbin` だけで、install.sh が要求する `brew`(xcodegen の導入元)が
    /// 見えない —— 入っているのに「Homebrew が無い」で落ちる(`RemoteShell.remoteRunCommand` と
    /// 同じ理由・同じ並び。片方だけ変えない)
    public static func runAndCleanupCommand(remotePath: String, args: [String]) -> String {
        let script = RemoteShell.quote(remotePath)
        let quotedArgs = args.map(RemoteShell.quote).joined(separator: " ")
        return "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; "
            + "bash \(script) \(quotedArgs); ft_status=$?; rm -f \(script); exit $ft_status"
    }

    /// git revision として埋め込む前の検証(16進 7〜40 文字のみ)。
    /// `alignRevisionCommand` へ渡す前に必ず呼ぶこと(`RemoteLayout.validateBase` と同じ、
    /// コマンドへ埋める前に入口で落とす規律)
    public static func validateRevision(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (7...40).contains(trimmed.count),
              trimmed.unicodeScalars.allSatisfy(hexDigits.contains) else {
            throw RemoteSetupError.invalidRevision(
                "must be a 7-40 character hex git revision: \"\(raw)\"")
        }
    }

    private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    /// リモートのクローンを発行側と同じコミットへ合わせ、`fleetest` と**配信ヘルパー**を
    /// 作り直す(docs/remote-runner.md §14 ステップ3 相当)。呼び出し側は `validateRevision` を
    /// 先に通すこと(ここでは検証しない — 検証は1箇所、埋め込みは複数箇所から呼ばれ得るため
    /// 分離してある)。
    ///
    /// **ヘルパーを省かない** —— `fleetest` だけを建てると、そのランナーのタイルは状態は届くのに
    /// 映像が1枚も来ない(`api device-stream` が exec 対象を見つけられず即死し、拡張は
    /// 「映像なし」で諦める)。名前の定義元は `StreamHelpers`
    public static func alignRevisionCommand(layout: RemoteLayout, revision: String) -> String {
        let builds = (["fleetest"] + StreamHelpers.all)
            .map { "swift build --product \($0)" }
            .joined(separator: " && ")
        return "cd \(RemoteShell.quote(layout.toolRoot)) && git fetch origin && "
            + "git checkout \(RemoteShell.quote(revision)) && " + builds
    }

    /// `--uninstall` が base ごと削除してよいかの判定(docs/remote-runner.md §14 撤去)。
    /// 拒否理由: ①空・相対パス(想定外の解決) ②"/" 丸ごと ③$HOME そのもの(ランナーのホームごと
    /// 消す) ④浅すぎる絶対パス(ルート直下1階層。例 "/tmp" "/etc" はシステムディレクトリ・
    /// 他用途のディレクトリと衝突しやすい)。**$HOME 配下限定はしない** — `--remote-dir` は
    /// home 外の専用ディスク(EC2 Mac 等)も許容する設計(docs/remote-runner.md §14)なので、
    /// 深さと明白な危険パスだけで判定する
    public static func validateUninstallBase(_ base: String, home: String) throws {
        guard !base.isEmpty else {
            throw RemoteSetupError.unsafeUninstallBase("base is empty")
        }
        guard base.hasPrefix("/") else {
            throw RemoteSetupError.unsafeUninstallBase("base must be an absolute path: \"\(base)\"")
        }
        guard base != "/" else {
            throw RemoteSetupError.unsafeUninstallBase("refusing to delete \"/\"")
        }
        let strippedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard base != strippedHome else {
            throw RemoteSetupError.unsafeUninstallBase("refusing to delete the HOME directory itself: \"\(base)\"")
        }
        let components = base.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            throw RemoteSetupError.unsafeUninstallBase(
                "path is too shallow to delete automatically (needs at least 2 path components): \"\(base)\"")
        }
    }

    public static func uninstallCommand(base: String) -> String {
        "rm -rf \(RemoteShell.quote(base))"
    }

    /// **ランナーは origin から fetch する**ので、手元だけにあるコミットへは合わせられない。
    /// そのまま撃つと `git checkout` が exit 128 で落ちるだけで理由が読めない(2026-08-16 に
    /// 実際に踏んだ)。押していないと分かっているなら、ssh を張る前にそう言う
    public static func unpublishedRevisionMessage(revision: String) -> String {
        "commit \(revision.prefix(7)) is not on any remote — the runner fetches from origin, "
            + "so push the branch first (git push), then re-run this command"
    }
}
