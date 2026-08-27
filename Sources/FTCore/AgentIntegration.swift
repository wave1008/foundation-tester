// AgentIntegration.swift
// 受け手が使うコーディングエージェント(Claude Code / Codex)ごとの**規約位置の唯一の定義元**。
//
// 契約: runbook 本体(SKILL.md)は複製しない。正典は canonicalSkillsDirectory の1箇所で、
// 各エージェントへは「規約位置から参照する薄いアダプタ」だけを置く(docs/design.md §15)。
// ここに無い規約位置を各所へ直書きすると、エージェントを1つ足すたびに散らばった定数を
// 探し歩くことになる。**シェル側(Scripts/install.sh・preflight.sh)にも同じ文字列があり、
// `vscode-fleetest/test/agentIntegration.test.mjs` が両者の一致を検出する**。

import Foundation

public enum AgentIntegration: String, CaseIterable, Sendable {
    case claude
    case codex
    case cline

    /// リポジトリ内の runbook 正典。**両エージェントともここを参照する**(複製しない)。
    /// Codex 側は `.agents/skills/<name>` のシンボリックリンクと `.codex-plugin/plugin.json` が
    /// ここへ向いている。**raw.githubusercontent はシンボリックリンクを本文でなくリンク先の
    /// 文字列として返す**ので、curl で取得する側(Scripts/install-skill.sh)は必ずこの実体パスを引く。
    public static let canonicalSkillsDirectory = ".claude/skills"

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cline: return "Cline"
        }
    }

    /// そのエージェントがスキルを探すディレクトリ(受け手のワークスペース基準)
    public var skillsDirectory: String {
        switch self {
        case .claude: return ".claude/skills"
        case .codex: return ".agents/skills"
        // Cline は `.claude/skills/` も読むが、**共有しない** —— 共有すると
        // 「Claude 用に置いた物を Cline も読む」暗黙の結合ができ、片方の都合で
        // 置き場所を変えたときにもう片方が黙って壊れる。公式推奨の専用位置を使う
        case .cline: return ".cline/skills"
        }
    }

    /// セッションの冒頭で読まれる指示ファイル。install.sh がマーカー付きで入口を書く先
    public var entryPointFile: String {
        switch self {
        case .claude: return "CLAUDE.md"
        case .codex: return "AGENTS.md"
        // **ファイルとディレクトリの両方があり得る**(Cline は `.clinerules` 単体ファイルでも
        // `.clinerules/` フォルダでも読む)。ディレクトリだったときの書き先は
        // install.sh が `.clinerules/fleetest.md` へ振り替える
        case .cline: return ".clinerules"
        }
    }

    /// スキルの明示呼び出し記法(入口の本文に出す)
    public var skillInvocationPrefix: String {
        switch self {
        case .claude: return "/"
        case .codex: return "$"
        case .cline: return "/"
        }
    }

    /// **コマンド単位の承認 allowlist を持つか**。Claude Code は `.claude/settings.json` の
    /// `permissions.allow` を持つが、**Codex は持たない**(承認は approval_policy と sandbox_mode の
    /// 粗い軸だけ)。持たない側に「等価物」を捏造しないための分岐。
    public var hasCommandPermissionAllowlist: Bool {
        switch self {
        case .claude: return true
        // Codex は approval_policy / sandbox_mode、Cline は auto-approve —— どちらも
        // 「このコマンドだけ許す」形を持たないので、等価物を捏造しない
        case .codex: return false
        case .cline: return false
        }
    }

    /// MCP サーバの登録先(人に見せる説明用)
    public var mcpRegistrationTarget: String {
        switch self {
        case .claude: return ".mcp.json"
        case .codex: return "~/.codex/config.toml"
        case .cline: return "~/.cline/mcp.json"
        }
    }

    public var cliName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cline: return "cline"
        }
    }

    /// 受け手がどのエージェントを使っているかの推定(純関数。I/O は presence クロージャへ逃がす)。
    /// **どれも見つからなければ Claude Code 単独に倒す** — 既存の受け手の挙動を変えないため。
    ///
    /// `ignoringWorkspaceSignals` は **workspace が fleetest のクローン自身のとき**に立てる。
    /// クローンは `.claude/` も `.agents/` も `CLAUDE.md` も持っているが、それは**このツールの
    /// アダプタ**であって受け手が Codex を使っている証拠ではない。見てしまうとどのクローンでも
    /// codex と判定され、クローンの中に AGENTS.md を書いて次の更新を pull ガードで止める。
    /// **Scripts/install.sh の clone 構成の分岐と同じ規則**(片方だけ変えない)。
    public static func detect(ignoringWorkspaceSignals: Bool = false,
                              exists: (String) -> Bool) -> [AgentIntegration] {
        var found: [AgentIntegration] = []
        let claudeSignals = ignoringWorkspaceSignals ? ["~/.claude"] : [".claude", "CLAUDE.md", "~/.claude"]
        let codexSignals = ignoringWorkspaceSignals ? ["~/.codex"] : [".agents", "AGENTS.md", "~/.codex"]
        let clineSignals = ignoringWorkspaceSignals ? ["~/.cline"] : [".cline", ".clinerules", "~/.cline"]
        if claudeSignals.contains(where: exists) { found.append(.claude) }
        if codexSignals.contains(where: exists) { found.append(.codex) }
        if clineSignals.contains(where: exists) { found.append(.cline) }
        return found.isEmpty ? [.claude] : found
    }

    /// CLI の `--agent` を解釈する。`nil`/空/`auto` は自動判定へ落とす。
    /// **install.sh が解決した結果をそのまま渡すための口** —— インストーラが `--agent codex` と
    /// 決めたのに CLI 側が独自に判定すると、**同じ実行の中で別々の結論が出る**
    /// (実際に踏んだ: 受け手のホームに `~/.claude` があるだけで Codex 専用の導入に
    /// `.claude/settings.json` ができた)。
    public static func parse(_ raw: String?, packageRoot: URL) -> [AgentIntegration] {
        parsed(raw)?.agents ?? detect(packageRoot: packageRoot)
    }

    /// `--agent` / state.json の値を解釈する I/O 無しの版。`nil` は「解釈できない(判定へ落とす)」。
    /// **知らない名前を黙って捨てない**: `unknown` に残して呼び手が警告できるようにする ——
    /// シェル側が知らない名前を素通しして「何もしないのに成功」を出した実害がある
    /// (`agents:"cursor"` で MCP 登録も入口も行われないまま `[ok]` になった)。
    public static func parsed(_ raw: String?) -> (agents: [AgentIntegration], unknown: [String])? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let tokens = raw.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        if tokens.contains("auto") { return nil }
        // **`both` は claude+codex の別名で「全部」ではない**(Cline を後から足したので
        // 取り違えやすい)。全部は `all`。シェル側の install-skill.sh / install.sh と同じ規則
        if tokens.contains("all") { return (allCases, []) }
        if tokens.contains("both") { return ([.claude, .codex], []) }
        let agents = tokens.compactMap(AgentIntegration.init(rawValue:))
        let unknown = tokens.filter { AgentIntegration(rawValue: $0) == nil }
        return agents.isEmpty ? nil : (agents, unknown)
    }

    /// ファイルシステムを見る版。`~/` 始まりはホーム基準、それ以外は packageRoot 基準。
    /// packageRoot が fleetest のクローン自身(= 受け手のパッケージではない)なら、
    /// ワークスペース側の手掛かりは見ない(上の doc を参照)。
    public static func detect(packageRoot: URL,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [AgentIntegration]
    {
        let isToolClone = !ProjectScaffold.isExternalPackage(repoRoot: packageRoot)
        return detect(ignoringWorkspaceSignals: isToolClone) { path in
            let url = path.hasPrefix("~/")
                ? home.appendingPathComponent(String(path.dropFirst(2)))
                : packageRoot.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}
