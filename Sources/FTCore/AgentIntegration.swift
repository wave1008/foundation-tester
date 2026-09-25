// AgentIntegration.swift
// 受け手が使うコーディングエージェント(Claude Code)の**規約位置の唯一の定義元**。
//
// 契約: runbook 本体(SKILL.md)は複製しない。正典は canonicalSkillsDirectory の1箇所。
// ここに無い規約位置を各所へ直書きすると、規約を1つ変えるたびに散らばった定数を
// 探し歩くことになる。**シェル側(Scripts/install.sh・preflight.sh)にも同じ文字列があり、
// `vscode-fleetest/test/agentIntegration.test.mjs` が両者の一致を検出する**。
//
// **インストーラが規約位置を用意するのは Claude Code だけ**(Codex を含む他のエージェントは
// 標準の stdio MCP サーバ + ツール中立の SKILL.md を自前の設定で読む = 規約位置を持たない。
// docs/user-docs/tools/other_agents.md)。エージェント判定の分岐をここへ戻さない ——
// 判定できない相手に「等価物」を捏造すると、書いた場所と読む場所が食い違ったまま
// **どちらも「正しく動く」**ので失敗が沈黙する。

import Foundation

public enum AgentIntegration {
    /// リポジトリ内の runbook 正典。プラグイン配布も curl 取得(Scripts/install-skill.sh)も
    /// この実体パスを引く
    public static let canonicalSkillsDirectory = ".claude/skills"

    public static let displayName = "Claude Code"

    /// エージェントがスキルを探すディレクトリ(受け手のワークスペース基準)
    public static let skillsDirectory = ".claude/skills"

    /// セッションの冒頭で読まれる指示ファイル。install.sh がマーカー付きで入口の**本文**を書く先。
    /// Claude Code(v2.1.277 以降)と AGENTS.md を読む他のエージェントの共通の入口
    public static let entryPointFile = "AGENTS.md"

    /// install.sh が `@AGENTS.md` の読み込みだけをマーカー付きで置く先。Claude Code は同じ場所か上に
    /// CLAUDE.md があると既定では AGENTS.md を読まず、古い版は AGENTS.md 自体を読まないため
    public static let claudeImportFile = "CLAUDE.md"

    /// スキルの明示呼び出し記法(入口の本文に出す)
    public static let skillInvocationPrefix = "/"

    /// MCP サーバの登録先(人に見せる説明用)
    public static let mcpRegistrationTarget = ".mcp.json"

    public static let cliName = "claude"
}
