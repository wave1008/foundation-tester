// アプリのパッケージ(.app ディレクトリ / .ipa)の中身を同じ口で読む。
// 読み手は3つ(AppBundleInspector の UI フレームワーク判定・実機用ビルドかの判定・アイコン名の候補)。
// **.ipa は展開しない**: 一覧は `unzip -Z1`、個々のファイルは `unzip -p`(stdout)で取り出す。
// 実機(devicectl)は .ipa をそのまま入れられるので、appPathPhysical に .ipa を書く受け手が居る。

import Foundation

public struct AppPackageReader {
    enum Package {
        case bundle(String)
        /// appPrefix = "Payload/<Name>.app/"
        case ipa(path: String, appPrefix: String, entries: [String])
    }

    let package: Package

    /// 開けなければ nil(パス無し・実在しない・.ipa に Payload/*.app が無い)
    public static func open(path: String?) -> AppPackageReader? {
        guard let path, !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return AppPackageReader(package: .bundle(path)) }
        guard (path as NSString).pathExtension.lowercased() == "ipa",
              let listing = try? Shell.run(["unzip", "-Z1", path], timeout: 60), listing.status == 0
        else { return nil }
        let entries = listing.output.split(whereSeparator: \.isNewline).map(String.init)
        guard let prefix = Self.appPrefix(entries: entries) else { return nil }
        return AppPackageReader(package: .ipa(path: path, appPrefix: prefix, entries: entries))
    }

    /// `Payload/<Name>.app/` を一覧から選ぶ純粋関数(ディレクトリ行が無い zip でも中のファイルから引く)
    static func appPrefix(entries: [String]) -> String? {
        for entry in entries where entry.hasPrefix("Payload/") {
            let rest = entry.dropFirst("Payload/".count)
            guard let slash = rest.firstIndex(of: "/") else { continue }
            let name = rest[..<slash]
            if name.hasSuffix(".app") { return "Payload/\(name)/" }
        }
        return nil
    }

    /// バンドル直下からの相対パス(ファイルでもディレクトリでも)が在るか
    public func exists(_ relative: String) -> Bool {
        switch package {
        case .bundle(let root):
            return FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(relative))
        case .ipa(_, let prefix, let entries):
            let file = prefix + relative
            let directory = file + "/"
            return entries.contains { $0 == file || $0 == directory || $0.hasPrefix(directory) }
        }
    }

    /// バンドル直下の名前(ディレクトリ名は末尾の "/" 無し)
    public func rootEntries() -> [String] {
        switch package {
        case .bundle(let root):
            return (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        case .ipa(_, let prefix, let entries):
            var names: [String] = []
            for entry in entries where entry.hasPrefix(prefix) {
                let rest = entry.dropFirst(prefix.count)
                guard !rest.isEmpty else { continue }
                let head = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if !head.isEmpty, !names.contains(head) { names.append(head) }
            }
            return names
        }
    }

    /// ファイルの中身(無い・読めない = nil)
    public func contents(_ relative: String) -> Data? {
        switch package {
        case .bundle(let root):
            return FileManager.default.contents(atPath: (root as NSString).appendingPathComponent(relative))
        case .ipa(let path, let prefix, let entries):
            let entry = prefix + relative
            guard entries.contains(entry),
                  let result = try? Shell.runData(["unzip", "-p", path, entry], timeout: 120),
                  result.status == 0 else { return nil }
            return result.data
        }
    }

    /// plist(binary / XML / 旧形式の .strings)を辞書として読む
    public func plist(_ relative: String) -> [String: Any]? {
        guard let data = contents(relative),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    public var infoPlist: [String: Any]? { plist("Info.plist") }

    /// ファイルにバイト列が含まれるか(読めなければ nil)
    public func contains(_ needle: String, in relative: String) -> Bool? {
        guard let data = contents(relative), let pattern = needle.data(using: .utf8) else { return nil }
        return data.range(of: pattern) != nil
    }
}
