// TransferIgnore.swift
// `--host` ディスパッチの転送(rsync)から外すパスを、転送対象のツリーの中の
// `.ftester-transfer-ignore` で宣言する口(docs/remote-runner.md §17「転送から外す」)。
//
// rsync 自身にも同じ機構(`-F` = dir-merge `.rsync-filter`)があるのに自前で読む理由:
// **macOS 標準の rsync(openrsync)では dir-merge の規則が `--delete` から受け側を守らない**
// (2026-08-23 実験: ローカル→ローカルで受け側の除外対象が消えた)。グローバルの `--exclude`
// なら守る(同日、M1Max への ssh 越しでも確認: 除外パスは送られず・受け側の既存ファイルは
// 残り・除外していない残骸だけ消えた)。受け手の実害は「ランナー機の台帳が手元の内容で
// 上書きされる」なので、**送らないだけでなく向こうの物を消さない**ことが要件。
// よってファイルは ftester が読み、すべて `--exclude` に翻訳して渡す。
//
// 翻訳の規則(rsync の `--exclude` の書き方をそのまま、**ファイルを置いたディレクトリ起点**で
// 読む = dir-merge と同じ感覚):
//   - 空行と `#` / `;` で始まる行は無視(rsync の --exclude-from と同じ)
//   - 先頭 `/` = そのディレクトリ直下に固定(`/data/temp/` → `<dir>/data/temp/` だけ)
//   - 先頭 `/` 無し = そのディレクトリ配下のどの深さでも一致(rsync の非固定パターンと同じ。
//     `*.log` は配下の全 .log、`data/temp/` は `<dir>/data/temp/` と `<dir>/x/data/temp/` の両方)
//   - 末尾 `/`(ディレクトリだけ)・`*` `?` `**` `[…]` はそのまま rsync へ渡る
//   - `+`/`-` で始める filter 規則の書式は受け付けない(行頭の `-` はパターンの一部として渡る)
// 非固定パターンを「配下のどの深さでも」にするには `<dir>/P` と `<dir>/**/P` の2本を出す
// (openrsync は `/<dir>/**/P` だけだと `<dir>/P` に当たらない。同日の実験で確認)。
// 転送ルート直下のファイル(dir = "")なら `/P` と `/**/P`。

import Foundation

public enum TransferIgnore {

    public static let fileName = ".ftester-transfer-ignore"

    /// 1回の転送で読んだ結果。`files` は転送ルートからの相対パス(ログ表示・テスト用)、
    /// `excludePatterns` は rsync の `--exclude` へそのまま渡す
    public struct Scan: Equatable, Sendable {
        public var files: [String]
        public var excludePatterns: [String]
        public static let none = Scan(files: [], excludePatterns: [])
        public init(files: [String], excludePatterns: [String]) {
            self.files = files
            self.excludePatterns = excludePatterns
        }
    }

    /// 1ファイルぶんの翻訳(純粋関数)。`directory` は転送ルートからの相対パス
    /// (ルート自身なら ""。先頭・末尾の "/" 無し)
    public static func excludePatterns(lines: [String], directory: String) -> [String] {
        let base = directory.isEmpty ? "" : "/" + directory
        var out: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line.hasPrefix("/") {
                out.append(base + line)
            } else {
                out.append(base + "/" + line)
                out.append(base + "/**/" + line)
            }
        }
        return out
    }

    /// 転送ルート配下の `.ftester-transfer-ignore` を全部読む。`skipTopLevel` は転送が除外する
    /// ルート直下の名前(そこは送られないので読まない)、`skipAnywhere` は階層を問わず除外する
    /// 名前(同じ理由 + `.git`/`node_modules` の走査を払わない)。`.app` 等のパッケージの中は
    /// 歩かない(`workspace/apps/` のステージング済みバンドルは数千ファイル)。見つけた順は
    /// パスの辞書順に固定する(rsync 引数が走るたびに並び替わらない)
    public static func scan(transferRoot: URL, skipTopLevel: Set<String>,
                            skipAnywhere: Set<String>) -> Scan {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: transferRoot,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsPackageDescendants])
        else { return .none }
        let rootPath = transferRoot.standardizedFileURL.path
        var found: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let name = url.lastPathComponent
            let isTopLevel = !relative.contains("/")
            if skipAnywhere.contains(name) || (isTopLevel && skipTopLevel.contains(name)) {
                enumerator.skipDescendants()
                continue
            }
            if name == fileName,
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
                found.append(relative)
            }
        }
        found.sort()
        var patterns: [String] = []
        for relative in found {
            let text = (try? String(contentsOf: transferRoot.appendingPathComponent(relative),
                                    encoding: .utf8)) ?? ""
            let directory = relative.hasSuffix("/" + fileName)
                ? String(relative.dropLast(fileName.count + 1)) : ""
            patterns += excludePatterns(lines: text.components(separatedBy: .newlines),
                                        directory: directory)
        }
        var seen = Set<String>()
        patterns = patterns.filter { seen.insert($0).inserted }
        return Scan(files: found, excludePatterns: patterns)
    }
}
