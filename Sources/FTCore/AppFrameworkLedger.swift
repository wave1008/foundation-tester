// UI フレームワークの判定結果を bundle ID ごとに覚える台帳(~/.fleetest/app-frameworks/<bundleID>.json)。
//
// 判定の材料(.app / .ipa)が**手元に無い**ときの唯一の答え —— 物理 iPhone は端末に入ったアプリの
// 中身をホストからもランナーからも読めない(2026-09-12 実測: devicectl にバンドルの領域は無く、
// ランナーのサンドボックスは Operation not permitted)。一度でも材料を見て判定できたら覚えておき、
// 次にファイルが無くても同じ bundle ID なら使う。**版が変わってもフレームワークは変わらない**前提。
// 同じファイルを毎回読み直さないための控え(path + mtime + size)も兼ねる(.ipa の実行ファイルは
// 50〜80MB で、シナリオごとの子プロセスが毎回展開すると 1 本あたり 0.5 秒払う)。
// 1 bundle ID = 1 ファイルなので、並列の子が同時に書いても混ざらない(rename の原子性だけで足りる)。
// **テストから既定の置き場へ書かない**(FMLiveness と同じ門: 環境変数の差し替えか production の opt-in)

import Foundation

public enum AppFrameworkLedger {
    public struct Entry: Codable, Equatable {
        public let framework: String
        /// 判定の材料(パス・更新時刻・大きさ)。材料無しで読むときは照合しない
        public let sourcePath: String?
        public let sourceModified: Double?
        public let sourceSize: Int?
    }

    static let directoryOverrideKey = "FT_APP_FRAMEWORK_DIR"

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest/app-frameworks", isDirectory: true)
    }

    static func fileURL(bundleID: String) -> URL {
        // bundle ID は "." と英数と "-" だけ(それ以外が来ても1ファイル名に収める)
        let safe = bundleID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    static var writesPermitted: Bool {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideKey], !override.isEmpty { return true }
        guard LedgerWriteRole.permitsProductionWrite else { return false }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    public static func load(bundleID: String) -> Entry? {
        guard let data = FileManager.default.contents(atPath: fileURL(bundleID: bundleID).path) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    public static func store(bundleID: String, entry: Entry) {
        guard writesPermitted, let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(bundleID: bundleID), options: .atomic)
    }

    /// 材料の指紋(無ければ nil = 照合できない)。.ipa はそのファイル、.app はディレクトリの mtime と
    /// Info.plist の大きさ(ディレクトリ自身の size は中身を数えない。ビルドし直せば Info.plist も書き直される)
    public static func fingerprint(path: String) -> (modified: Double, size: Int)? {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        var isDirectory: ObjCBool = false
        _ = fm.fileExists(atPath: path, isDirectory: &isDirectory)
        let sizeSource = isDirectory.boolValue ? (path as NSString).appendingPathComponent("Info.plist") : path
        let size = ((try? fm.attributesOfItem(atPath: sizeSource))?[.size] as? Int) ?? 0
        return (modified.timeIntervalSince1970, size)
    }
}
