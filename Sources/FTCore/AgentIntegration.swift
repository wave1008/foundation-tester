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

    /// リポジトリ内の runbook 正典。**両エージェントともここを参照する**(複製しない)。
    /// Codex 側は `.agents/skills/<name>` のシンボリックリンクと `.codex-plugin/plugin.json` が
    /// ここへ向いている。**raw.githubusercontent はシンボリックリンクを本文でなくリンク先の
    /// 文字列として返す**ので、curl で取得する側(Scripts/install-skill.sh)は必ずこの実体パスを引く。
    public static let canonicalSkillsDirectory = ".claude/skills"

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// そのエージェントがスキルを探すディレクトリ(受け手のワークスペース基準)
    public var skillsDirectory: String {
        switch self {
        case .claude: return ".claude/skills"
        case .codex: return ".agents/skills"
        }
    }

    /// セッションの冒頭で読まれる指示ファイル。install.sh がマーカー付きで入口を書く先
    public var entryPointFile: String {
        switch self {
        case .claude: return "CLAUDE.md"
        case .codex: return "AGENTS.md"
        }
    }

    /// スキルの明示呼び出し記法(入口の本文に出す)
    public var skillInvocationPrefix: String {
        switch self {
        case .claude: return "/"
        case .codex: return "$"
        }
    }

    /// **コマンド単位の承認 allowlist を持つか**。Claude Code は `.claude/settings.json` の
    /// `permissions.allow` を持つが、**Codex は持たない**(承認は approval_policy と sandbox_mode の
    /// 粗い軸だけ)。持たない側に「等価物」を捏造しないための分岐。
    public var hasCommandPermissionAllowlist: Bool {
        switch self {
        case .claude: return true
        case .codex: return false
        }
    }

    /// MCP サーバの登録先(人に見せる説明用)
    public var mcpRegistrationTarget: String {
        switch self {
        case .claude: return ".mcp.json"
        case .codex: return "~/.codex/config.toml"
        }
    }

    public var cliName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    /// 受け手がどのエージェントを使っているかの推定(純関数。I/O は presence クロージャへ逃がす)。
    /// **どれも見つからなければ Claude Code 単独に倒す** — 既存の受け手の挙動を変えないため。
    public static func detect(exists: (String) -> Bool) -> [AgentIntegration] {
        var found: [AgentIntegration] = []
        if exists(".claude") || exists("CLAUDE.md") || exists("~/.claude") { found.append(.claude) }
        if exists(".agents") || exists("AGENTS.md") || exists("~/.codex") { found.append(.codex) }
        return found.isEmpty ? [.claude] : found
    }

    /// CLI の `--agent` を解釈する。`nil`/空/`auto` は自動判定へ落とす。
    /// **install.sh が解決した結果をそのまま渡すための口** —— インストーラが `--agent codex` と
    /// 決めたのに CLI 側が独自に判定すると、**同じ実行の中で別々の結論が出る**
    /// (実際に踏んだ: 受け手のホームに `~/.claude` があるだけで Codex 専用の導入に
    /// `.claude/settings.json` ができた)。
    public static func parse(_ raw: String?, packageRoot: URL) -> [AgentIntegration] {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return detect(packageRoot: packageRoot)
        }
        let tokens = raw.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        if tokens.contains("auto") { return detect(packageRoot: packageRoot) }
        if tokens.contains("both") { return allCases }
        let parsed = tokens.compactMap(AgentIntegration.init(rawValue:))
        return parsed.isEmpty ? detect(packageRoot: packageRoot) : parsed
    }

    /// ファイルシステムを見る版。`~/` 始まりはホーム基準、それ以外は packageRoot 基準。
    public static func detect(packageRoot: URL,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [AgentIntegration]
    {
        detect { path in
            let url = path.hasPrefix("~/")
                ? home.appendingPathComponent(String(path.dropFirst(2)))
                : packageRoot.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}
