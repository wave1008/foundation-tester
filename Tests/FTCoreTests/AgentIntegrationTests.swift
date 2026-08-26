// AgentIntegration の規約位置と自動判定。
//
// ここが唯一の定義元(シェル側との一致は vscode-fleetest/test/agentIntegration.test.mjs)。
// 判定を緩めると、CLI が書いた場所とインストーラが見る場所が食い違い、**どちらも
// 「正しく動く」まま別の場所を触る**ので、失敗が沈黙する。

import XCTest
@testable import FTCore

final class AgentIntegrationTests: XCTestCase {

    // MARK: - 規約位置

    func testConventionsAreDistinctPerAgent() {
        XCTAssertEqual(AgentIntegration.claude.skillsDirectory, ".claude/skills")
        XCTAssertEqual(AgentIntegration.codex.skillsDirectory, ".agents/skills")
        XCTAssertEqual(AgentIntegration.claude.entryPointFile, "CLAUDE.md")
        XCTAssertEqual(AgentIntegration.codex.entryPointFile, "AGENTS.md")
        XCTAssertEqual(AgentIntegration.claude.skillInvocationPrefix, "/")
        XCTAssertEqual(AgentIntegration.codex.skillInvocationPrefix, "$")
        // 規約位置は**エージェント間で衝突しない**こと(同じ場所を2つが取り合うと
        // 片方の入口をもう片方が上書きする)
        XCTAssertEqual(Set(AgentIntegration.allCases.map(\.skillsDirectory)).count,
                       AgentIntegration.allCases.count)
        XCTAssertEqual(Set(AgentIntegration.allCases.map(\.entryPointFile)).count,
                       AgentIntegration.allCases.count)
    }

    /// 正典は1つ。**Claude 側の規約位置と同じ**(Codex 側はここへのシンボリックリンク)。
    /// ここを Codex 側へ移すと、install-skill.sh の curl 取得がリンク先の文字列を掴む
    func testCanonicalSkillsDirectoryIsTheClaudeLocation() {
        XCTAssertEqual(AgentIntegration.canonicalSkillsDirectory,
                       AgentIntegration.claude.skillsDirectory)
    }

    /// **Codex にコマンド単位の承認 allowlist は無い**。等価物を捏造しないための分岐
    func testOnlyClaudeHasACommandPermissionAllowlist() {
        XCTAssertTrue(AgentIntegration.claude.hasCommandPermissionAllowlist)
        XCTAssertFalse(AgentIntegration.codex.hasCommandPermissionAllowlist)
    }

    // MARK: - 自動判定(純関数)

    func testDetectFallsBackToClaudeWhenNothingIsPresent() {
        XCTAssertEqual(AgentIntegration.detect { _ in false }, [.claude])
    }

    func testDetectPicksCodexFromEachOfItsSignals() {
        for signal in [".agents", "AGENTS.md", "~/.codex"] {
            XCTAssertEqual(AgentIntegration.detect { $0 == signal }, [.codex],
                           "手掛かり \(signal) から codex を拾えていない")
        }
    }

    func testDetectPicksClaudeFromEachOfItsSignals() {
        for signal in [".claude", "CLAUDE.md", "~/.claude"] {
            XCTAssertEqual(AgentIntegration.detect { $0 == signal }, [.claude],
                           "手掛かり \(signal) から claude を拾えていない")
        }
    }

    func testDetectReturnsBothWhenBothArePresent() {
        XCTAssertEqual(AgentIntegration.detect { $0 == "CLAUDE.md" || $0 == "AGENTS.md" },
                       [.claude, .codex])
    }

    /// ホーム側の手掛かりは `~/` 始まりでファイルシステム版と区別される。
    /// パッケージ内の `.codex` を見て codex と判定してはいけない(そんな規約位置は無い)
    func testDetectDoesNotTreatAPackageLocalDotCodexAsASignal() {
        XCTAssertEqual(AgentIntegration.detect { $0 == ".codex" }, [.claude])
    }

    // MARK: - --agent のパース(インストーラの決定を CLI へ渡す口)

    func testParseAcceptsExplicitAgents() {
        let root = URL(fileURLWithPath: "/nonexistent-package-root")
        XCTAssertEqual(AgentIntegration.parse("codex", packageRoot: root), [.codex])
        XCTAssertEqual(AgentIntegration.parse("claude", packageRoot: root), [.claude])
        XCTAssertEqual(AgentIntegration.parse("both", packageRoot: root), AgentIntegration.allCases)
        // install.sh は空白区切りで持っているのでカンマへ畳んで渡す。どちらの区切りでも読む
        XCTAssertEqual(AgentIntegration.parse("claude,codex", packageRoot: root), [.claude, .codex])
        XCTAssertEqual(AgentIntegration.parse("claude codex", packageRoot: root), [.claude, .codex])
        XCTAssertEqual(AgentIntegration.parse("CODEX", packageRoot: root), [.codex])
    }

    /// 未指定・空・auto・解釈できない値は自動判定へ落とす(引数の綴り違いで**黙って何も
    /// しない**より、判定に戻すほうが安全)
    func testParseFallsBackToDetection() {
        let root = URL(fileURLWithPath: "/nonexistent-package-root")
        let home = URL(fileURLWithPath: "/nonexistent-home")
        let detected = AgentIntegration.detect(packageRoot: root, home: home)
        for raw in [nil, "", "   ", "auto", "cursor"] {
            XCTAssertEqual(AgentIntegration.parse(raw, packageRoot: root).isEmpty, false,
                           "\(raw ?? "nil") で空になってはいけない")
        }
        XCTAssertEqual(detected, [.claude], "手掛かりが無ければ claude 単独")
    }

    // MARK: - ファイルシステム版

    func testDetectOnDiskReadsPackageAndHomeSeparately() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ft-agent-\(UUID().uuidString)")
        let home = fm.temporaryDirectory.appendingPathComponent("ft-home-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: home) }

        XCTAssertEqual(AgentIntegration.detect(packageRoot: root, home: home), [.claude],
                       "何も無ければ claude 単独へ倒す")

        try "".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentIntegration.detect(packageRoot: root, home: home), [.codex])

        try fm.createDirectory(at: home.appendingPathComponent(".claude"),
                               withIntermediateDirectories: true)
        XCTAssertEqual(AgentIntegration.detect(packageRoot: root, home: home), [.claude, .codex])
    }
}
