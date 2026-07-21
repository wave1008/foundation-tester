// autoInstall の差分スキップ判定(iOS シミュレータ)。利用側: BridgeProvisioner(inapp の
// 注入起動前)と ProfileWorkerFactory.installIfNeeded(xcuitest エンジンの実行前インストール)。

import CryptoKit
import Foundation
import FTCore

public enum InstalledAppCheck {
    /// インストール済みアプリがインストールファイル(.app)と同一内容か。simctl install はバンドルを
    /// バイト同一でコピーする(実測)ため、ディレクトリの深比較で「更新の有無」を判定できる。
    /// 深比較は約40MBのバンドルで0.8〜0.9s/ラン掛かるため、検証済みのソース指紋
    /// (相対パス+サイズ+mtime のハッシュ)を .ftester/install-check/ にキャッシュし、
    /// ①コンテナ実在(erase 検知)+②指紋一致 なら深比較をスキップする(実測 0.86s→0.1s)。
    /// 未インストール・比較不能は false(=要インストール)。
    public static func simulatorAppIsCurrent(udid: String, bundleID: String, appPath: String) -> Bool {
        guard let container = try? Shell.run(
            ["xcrun", "simctl", "get_app_container", udid, bundleID]),
            container.status == 0 else { return false }
        let installedPath = container.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !installedPath.isEmpty else { return false }

        let fingerprint = sourceFingerprint(appPath: appPath)
        if let fingerprint, fingerprint == cachedFingerprint(udid: udid, bundleID: bundleID) {
            return true
        }
        let equal = FileManager.default.contentsEqual(atPath: appPath, andPath: installedPath)
        if equal, let fingerprint {
            storeFingerprint(fingerprint, udid: udid, bundleID: bundleID)
        }
        return equal
    }

    /// インストール直後に呼ぶと次回以降の深比較をスキップできる(呼ばなくても初回深比較で自己回復)
    public static func recordInstalled(udid: String, bundleID: String, appPath: String) {
        guard let fingerprint = sourceFingerprint(appPath: appPath) else { return }
        storeFingerprint(fingerprint, udid: udid, bundleID: bundleID)
    }

    /// ソース .app の指紋: 全ファイルの(相対パス, サイズ, mtime)を列挙してハッシュ。
    /// バイト読み出しをしないため 40MB バンドルでも数十ms。ビルドし直しは mtime が変わるため検知できる
    private static func sourceFingerprint(appPath: String) -> String? {
        let root = URL(fileURLWithPath: appPath)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: []) else { return nil }
        var lines: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            let rel = url.path.dropFirst(root.path.count)
            let size = values.fileSize ?? 0
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            lines.append("\(rel)\t\(size)\t\(mtime)")
        }
        lines.sort()  // enumerator の順序は保証されないため安定化
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheURL(udid: String, bundleID: String) -> URL? {
        guard let root = try? RepoRoot.find() else { return nil }
        return root.appendingPathComponent(".ftester/install-check/\(udid)-\(bundleID).txt")
    }

    private static func cachedFingerprint(udid: String, bundleID: String) -> String? {
        guard let url = cacheURL(udid: udid, bundleID: bundleID) else { return nil }
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func storeFingerprint(_ fingerprint: String, udid: String, bundleID: String) {
        guard let url = cacheURL(udid: udid, bundleID: bundleID) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? fingerprint.write(to: url, atomically: true, encoding: .utf8)
    }
}
