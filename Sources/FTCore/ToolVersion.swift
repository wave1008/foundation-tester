// ToolVersion.swift
// `fleetest --version` の文言。git を spawn せず `.git` の中身を直接読む(ArgumentParser の
// version はコマンド起動のたびに評価されうるため、プロセス起動コストを払わない)。
// 失敗は必ず "unknown" へ潰す(バイナリの --version がリポジトリの状態次第でクラッシュ/警告する
// のは受け手体験として最悪)。

import Foundation

public enum ToolVersion {
    /// 実行中のバイナリのディレクトリを起点に `.git` を探す。`Bundle.main.executableURL` が
    /// 取れない環境(一部のテストランナー等)では `CommandLine.arguments[0]` をカレントディレクトリ
    /// 基準で解決してフォールバックする
    public static func describe() -> String {
        let startDir: URL
        if let executableURL = Bundle.main.executableURL {
            startDir = executableURL.deletingLastPathComponent()
        } else {
            startDir = URL(fileURLWithPath: CommandLine.arguments[0],
                           relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .deletingLastPathComponent()
        }
        return describe(startingAt: startDir)
    }

    /// テストのために探索の起点を注入できるようにした本体。`.build/<config>/fleetest` から
    /// `.git` までは数階層(リポジトリ構成が変わっても大きくは動かない)なので 10 段は十分な余裕
    static func describe(startingAt startDir: URL) -> String {
        "\(revision(startingAt: startDir) ?? "unknown") (protocol \(fleetestProtocolVersion))"
    }

    private static func revision(startingAt startDir: URL) -> String? {
        var dir = startDir
        for _ in 0..<10 {
            let gitURL = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
                // worktree の `.git` はファイル(gitdir: <path>)—— この経路はサポートしない
                guard isDirectory.boolValue else { return nil }
                return sha(inRepo: gitURL)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func sha(inRepo gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else {
            return nil
        }
        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHead.hasPrefix("ref: ") else {
            return normalizedSHA(trimmedHead)
        }
        let ref = String(trimmedHead.dropFirst("ref: ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = try? String(contentsOf: gitDir.appendingPathComponent(ref), encoding: .utf8) {
            return normalizedSHA(direct.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return shaFromPackedRefs(gitDir: gitDir, ref: ref)
    }

    /// `git gc` 後は緩んだ ref が packed-refs へ畳まれ、`refs/heads/<name>` が消えることがある
    private static func shaFromPackedRefs(gitDir: URL, ref: String) -> String? {
        guard let packed = try? String(contentsOf: gitDir.appendingPathComponent("packed-refs"),
                                       encoding: .utf8) else { return nil }
        for line in packed.split(separator: "\n") where line.hasSuffix(" \(ref)") {
            let sha = line.split(separator: " ").first.map(String.init)
            if let sha { return normalizedSHA(sha) }
        }
        return nil
    }

    /// 40 桁(または短縮)16進の見た目をしていないものは失敗扱い(空・壊れた読みを "unknown" へ)。
    /// 下限4桁は「明らかに SHA でない」(空・1文字のゴミ)を弾くための緩い足切りで、git の
    /// 短縮 SHA の実務上の最短(4桁)に合わせてある。表示は先頭 12 桁(それより短ければそのまま)
    private static func normalizedSHA(_ raw: String) -> String? {
        guard (4...40).contains(raw.count),
              raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(raw.prefix(12))
    }
}
