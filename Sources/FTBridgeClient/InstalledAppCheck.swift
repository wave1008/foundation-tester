// autoInstall の差分スキップ判定(iOS シミュレータ)。利用側: BridgeProvisioner(inapp の
// 注入起動前)と ProfileWorkerFactory.installIfNeeded(xcuitest エンジンの実行前インストール)。

import CryptoKit
import Foundation
import FTCore

public enum InstalledAppCheck {
    /// インストール済みアプリがインストールファイル(.app)と同一内容か。simctl install はバンドルを
    /// バイト同一でコピーする(実測)ため、ディレクトリの深比較で「更新の有無」を判定できる。
    /// 深比較は約40MBのバンドルで0.8〜0.9s/ラン掛かるため、検証済みのソース指紋
    /// (相対パス+サイズ+mtime のハッシュ)を .fleetest/install-check/ にキャッシュし、
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

    /// 判定できなかった理由を持つ(**沈黙させないため**。理由が出ないと、ガードが
    /// 素通ししていることに誰も気付けない —— 2026-08-06 に受け手側で実際に起きた)
    public enum InstallVerdict: Equatable {
        case installed
        case notInstalled
        case unknown(String)
    }

    /// 起動中シミュレータにそのアプリが入っているか。ブリッジ側は未インストールと未起動を
    /// 区別できない(XCUIApplication はどちらも notRunning のまま)ため、ホストが udid で確かめる。
    /// 相関がデバイス**名**なのは `/status` が名前しか返さないため(XCUIBridgeResolver と同じ制約)
    public static func simulatorInstallVerdict(deviceName: String, bundleID: String) -> InstallVerdict {
        let booted = ((try? SimulatorCatalog.devices()) ?? [])
            .filter { $0.booted && !$0.physical && $0.name == deviceName }
        var installedFlags: [Bool] = []
        for device in booted {
            guard let result = try? Shell.run(
                ["xcrun", "simctl", "get_app_container", device.udid, bundleID],
                timeout: 15) else {
                return .unknown("simctl get_app_container failed for \(device.udid)")
            }
            installedFlags.append(result.status == 0)
        }
        return verdict(deviceName: deviceName, installedFlags: installedFlags)
    }

    /// **同名が複数でも「どれにも入っていない」なら断定できる**(どれが宛先でも未インストール)。
    /// 既定名のシミュレータを2台起動している受け手は珍しくないので、
    /// 「一意に引けたときだけ判定する」では素通りする
    static func verdict(deviceName: String, installedFlags: [Bool]) -> InstallVerdict {
        guard !installedFlags.isEmpty else {
            return .unknown("no booted simulator is named \"\(deviceName)\"")
        }
        if installedFlags.allSatisfy({ $0 == false }) { return .notInstalled }
        if installedFlags.count == 1 { return .installed }
        return .unknown("\(installedFlags.count) booted simulators are named \"\(deviceName)\""
            + " and the app is installed on some of them")
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
        return root.appendingPathComponent(".fleetest/install-check/\(udid)-\(bundleID).txt")
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
