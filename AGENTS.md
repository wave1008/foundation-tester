# fleetest mobile — AGENTS.md を読むエージェント(Codex など)向けの入口

**このリポジトリの規則の本体は `CLAUDE.md` にある**(Claude Code 向けの名前だが、規則はエージェントを
問わない)。**作業の前に `CLAUDE.md` を全部読む**。このファイルには規則の本文を書かない —— 二重に持つと
片方だけ直す事故になる(規則を足す・直すのは CLAUDE.md と `.claude/rules/` の側)。

## Claude Code と違うところ

- **領域ごとの規則ファイル `.claude/rules/<領域>.md` は自動では読み込まれない**。Claude Code はその領域の
  ファイルを読んだときに自動で読み込むが、他のエージェントには届かない。**CLAUDE.md の「領域ごとの規律」の
  表を見て、その領域のファイルを触る前に該当する規則ファイルを自分で読む**(先頭の `paths:` が
  その規則の効くファイル)。CLAUDE.md の規律の約8割はこちらにある
- **スキルは手順書として読む**。`.claude/skills/<名前>/SKILL.md` はツール中立の markdown で、
  `/fleetest-setup` のような呼び出しの仕組みは無いので、該当する SKILL.md を読んで従う
- **MCP(`ft_*`)の登録と Codex のサンドボックス**は docs/user-docs/tools/other_agents_ja.md。
  サンドボックスが縛るのはシェルだけで、ビルド・テスト・導入(シェル経由)は設定に左右される ——
  `network_access` / `writable_roots` の値を根拠に「通る」と断定しない
