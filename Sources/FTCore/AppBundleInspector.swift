// engine=xcuitest ではブリッジが uiFramework を自己申告しない(InAppBridge だけが持つ /status
// フィールド)ため、ホスト側がバンドルのマーカーから同じ判定をする。マーカー規則は
// InAppBridge.uiFramework(InAppBridge/Sources/InAppBridge.swift:32-42)と同一 — 片方だけ変えない。
// in-app/hybrid は probe の自己申告(probeStatus?.uiFramework)をそのまま使うのでここを呼ばない。

import Foundation

public enum AppBundleInspector {
    /// バンドル直下のマーカー実在から判定する純粋関数(単体テスト対象。プロセス起動は分離)。
    /// 優先順位は InAppBridge と同じ(compose を先に見る)
    public static func uiFramework(composeResourcesExists: Bool, flutterFrameworkExists: Bool) -> String {
        if composeResourcesExists { return "compose" }
        if flutterFrameworkExists { return "flutter" }
        return "uikit"
    }

    /// ビルド済み .app のパスから直接判定する(FileManager のみ・サブプロセス無し)。
    /// パス未指定・実在しないパスは nil(呼び出し側が simctl 版へ落ちる)
    public static func detect(appPath: String?) -> String? {
        guard let appPath, FileManager.default.fileExists(atPath: appPath) else { return nil }
        let bundle = appPath as NSString
        let fm = FileManager.default
        return uiFramework(
            composeResourcesExists: fm.fileExists(
                atPath: bundle.appendingPathComponent("compose-resources")),
            flutterFrameworkExists: fm.fileExists(
                atPath: bundle.appendingPathComponent("Frameworks/Flutter.framework")))
    }

    /// Simulator 上のインストール済みアプリのバンドルを調べて uiFramework を返す。
    /// **コマンド失敗・実機・udid 不明は nil**(呼び出し側は「不明」として shouldEmptyDrag を
    /// 従来どおり true 側に倒す)
    public static func detect(udid: String?, bundleID: String, physical: Bool) -> String? {
        guard !physical, let udid, !udid.isEmpty else { return nil }
        guard let result = try? Shell.run(
            ["xcrun", "simctl", "get_app_container", udid, bundleID, "app"], timeout: 10),
            result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let bundle = path as NSString
        let fm = FileManager.default
        let composeExists = fm.fileExists(atPath: bundle.appendingPathComponent("compose-resources"))
        let flutterExists = fm.fileExists(
            atPath: bundle.appendingPathComponent("Frameworks/Flutter.framework"))
        return uiFramework(composeResourcesExists: composeExists, flutterFrameworkExists: flutterExists)
    }
}
