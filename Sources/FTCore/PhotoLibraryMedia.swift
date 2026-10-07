// PhotoLibraryMedia.swift
// DSL `addMedia(_:)` が写真ライブラリへ入れるファイルの規則(唯一の定義元)。DSL・ドライバ(BridgeClient / AndroidDriver)・
// サンドボックスの方針(`SimctlPolicy` / `AdbPolicy`)が同じ規則を引く。**送れるのはデータセットのフォルダの中だけ**:
// 親の broker は子の代わりにファイルを読むので、子が読めない場所(`~/.ssh` 等)を写真ライブラリへ送り出す口にしない。

import Foundation

public enum PhotoLibraryMedia {
    public enum Kind: Sendable, Equatable {
        case image, video
    }

    /// 送れる拡張子(小文字。照合は大文字小文字を問わない)
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "gif"]
    static let videoExtensions: Set<String> = ["mp4", "mov"]

    public static func kind(ofFileName name: String) -> Kind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// `addMedia` の置き場の解決(`dataFile` と同じ `ScenarioDataset.resolveFile`)+ 拡張子の確認
    public static func resolve(_ filename: String, projectDir: URL?, home: String = ScenarioSandbox.realHome())
        -> Result<(url: URL, kind: Kind), ScenarioDataset.Failure> {
        guard let kind = kind(ofFileName: filename) else {
            return .failure(.init(message: "addMedia(\(filename.debugDescription)): unsupported file type."
                + " Images: jpg, jpeg, png, heic, gif. Videos: mp4, mov"))
        }
        switch ScenarioDataset.resolveFile(filename, projectDir: projectDir, home: home) {
        case .success(let url): return .success((url, kind))
        case .failure(let failure): return .failure(failure)
        }
    }

    /// 親が読んでよい置き場の根(`ScenarioDataset.resolveFile` の2つの置き場と同じ)
    public static func datasetRoots(projectRoot: String, home: String) -> [String] {
        let name = URL(fileURLWithPath: projectRoot).standardizedFileURL.lastPathComponent
        return [projectRoot + "/dataset", home + "/.config/fleetest/dataset/" + name]
    }

    /// 親が写真ライブラリへ送ってよい元ファイルか。絶対パスで、**symlink を解決した後**がデータセットの根の中にあり、
    /// 拡張子が送れるもの(`..` や symlink で外へ出る形を断る)
    public static func isAllowedSource(_ path: String, roots: [String]) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let real = ScenarioSandbox.canonicalPath(path)
        guard kind(ofFileName: real) != nil else { return false }
        return roots.contains { root in
            let realRoot = ScenarioSandbox.canonicalPath(root)
            return real.hasPrefix(realRoot + "/")
        }
    }

    // MARK: Android

    /// 端末の sh へそのまま渡してよい名前(英数字・`.`・`-`・`_` だけ)。`adb shell` は引数を空白で結合して端末の sh に
    /// 解釈し直させるので、引用で逃げずに文字を絞る
    public static func isShellSafeBasename(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    public static func androidDirectory(_ kind: Kind) -> String { kind == .image ? "Pictures" : "Movies" }

    static func androidRemotePath(_ kind: Kind, basename: String) -> String {
        "/sdcard/\(androidDirectory(kind))/\(basename)"
    }

    /// `adb push <元> /sdcard/<Pictures|Movies>/<名前>` の引数列(`-s <serial>` を除く)
    public static func androidPushArguments(local: String, kind: Kind, basename: String) -> [String] {
        ["push", local, androidRemotePath(kind, basename: basename)]
    }

    /// API 29 以前の端末のための再スキャン(API 35 の Emulator では push の時点で登録済み)
    public static func androidScanArguments(kind: Kind, basename: String) -> [String] {
        ["shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
         "-d", "file://" + androidRemotePath(kind, basename: basename)]
    }

    /// 登録の確認。出力に `_display_name=<名前>` の行が並ぶ
    public static func androidQueryArguments(kind: Kind) -> [String] {
        ["shell", "content", "query", "--uri",
         "content://media/external/\(kind == .image ? "images" : "video")/media", "--projection", "_display_name"]
    }

    /// `content query` の出力(`Row: 0 _display_name=<名前>`)に、その名前の行があるか(部分一致で別の名前を拾わない)
    public static func queryOutputContains(_ output: String, basename: String) -> Bool {
        let key = "_display_name="
        return output.split(whereSeparator: \.isNewline).contains { line in
            guard let range = line.range(of: key) else { return false }
            return line[range.upperBound...].trimmingCharacters(in: .whitespaces) == basename
        }
    }

    /// `AdbPolicy` 用: `push` の宛先が `/sdcard/(Pictures|Movies)/<安全な名前>` で、拡張子が置き場と合っているか
    static func androidRemoteKind(_ remote: String) -> (kind: Kind, basename: String)? {
        for kind in [Kind.image, .video] {
            let prefix = "/sdcard/\(androidDirectory(kind))/"
            guard remote.hasPrefix(prefix) else { continue }
            let basename = String(remote.dropFirst(prefix.count))
            guard isShellSafeBasename(basename), PhotoLibraryMedia.kind(ofFileName: basename) == kind else { return nil }
            return (kind, basename)
        }
        return nil
    }
}
