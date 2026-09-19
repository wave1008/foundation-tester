// findImage / findImages の見本(DefaultClassifier の見本画像)の特徴量の永続控え。
// 置き場は `<project>/.fleetest/vision/template-prints.json` の1ファイル(鍵 = プロジェクトからの相対パス)。
// シナリオは1本ごとに別プロセスなので、プロセス内の控え(FindImage.templatePrints)だけでは見本を毎回計算し直す。
//
// 規律:
//   - **差分更新**: 画像の中身(sha256)と OS の版が控えと一致する見本だけ使う。違えばその1件だけ計算し直す
//     (OS の更新で Vision の特徴量が変わりうる)。書くときに、もう無い見本の行を刈る
//   - **書くのは門を通った特徴量だけ**(FindImage.match が縮退・測り直しの確認を通した後に `record`)。
//     門で落ちた見本は `drop` で消す = 壊れた状態の特徴量を次の run へ持ち越さない
//   - 並列のシナリオ実行プロセスが同時に書くので、読み・更新・置き換えはロックの内側(flock)で行う。
//     控えなので読めない・壊れているときは空として扱う(計算し直すだけ)

import CryptoKit
import Foundation
import Vision

enum TemplatePrintStore {
    struct Entry: Codable {
        var sha256: String
        var osBuild: String
        var print: FeaturePrintObservation
    }

    struct Contents: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    static let fileName = "template-prints.json"

    /// Vision の特徴量は OS の版で変わりうるので、控えの鍵に含める
    static let currentOSBuild = ProcessInfo.processInfo.operatingSystemVersionString

    /// 見本の置き場(`<project>/vision/classifiers/…`)からプロジェクトと相対パスを割り出す。
    /// 置き場の外の画像(テストの一時ファイル等)は nil = 永続化しない
    static func location(of template: URL) -> (file: URL, key: String)? {
        let path = template.standardizedFileURL.path
        guard let range = path.range(of: "/vision/classifiers/") else { return nil }
        let root = URL(fileURLWithPath: String(path[..<range.lowerBound]), isDirectory: true)
        let key = String(path[path.index(after: range.lowerBound)...])
        return (root.appendingPathComponent(".fleetest/vision/\(fileName)"), key)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 中身と OS の版が一致する控えの特徴量。無ければ nil
    static func lookup(_ template: URL, osBuild: String = currentOSBuild) -> FeaturePrintObservation? {
        guard let (file, key) = location(of: template),
              let data = try? Data(contentsOf: template),
              let entry = read(file).entries[key],
              entry.osBuild == osBuild, entry.sha256 == digest(data) else { return nil }
        return entry.print
    }

    /// 門を通った特徴量を書く(その見本の行だけ差し替え、もう無い見本の行を刈る)
    static func record(_ template: URL, print: FeaturePrintObservation, osBuild: String = currentOSBuild) {
        guard let (file, key) = location(of: template), let data = try? Data(contentsOf: template) else { return }
        update(file) { contents in
            contents.entries[key] = Entry(sha256: digest(data), osBuild: osBuild, print: print)
        }
    }

    /// 門で落ちた見本の控えを消す
    static func drop(_ template: URL) {
        guard let (file, key) = location(of: template) else { return }
        update(file) { $0.entries[key] = nil }
    }

    static func read(_ file: URL) -> Contents {
        guard let data = try? Data(contentsOf: file),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return Contents() }
        return contents
    }

    private static func update(_ file: URL, _ change: (inout Contents) -> Void) {
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // FileManager.createFile を使わない(既存の inode を置き換えて先客の flock と衝突しなくなる)
        let fd = open(directory.appendingPathComponent("\(fileName).lock").path, O_WRONLY | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }
        var contents = read(file)
        change(&contents)
        // プロジェクトの外へ出た見本・消えた見本の行を刈る(鍵はプロジェクトからの相対パス)
        let root = directory.deletingLastPathComponent().deletingLastPathComponent()
        contents.entries = contents.entries.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0.key).path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(contents) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
