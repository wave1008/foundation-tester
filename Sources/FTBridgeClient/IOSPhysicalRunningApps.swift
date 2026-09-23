// iOS 実機で「今 起動しているアプリ」の bundle ID。ライブ操作の前面追従(LiveSessionFollower)が
// 前面かを聞く候補に使う —— シミュレータの `simctl spawn <udid> launchctl list` に相当する口が
// 実機には無いので、`devicectl device info processes`(実行ファイルのパスだけ。bundle ID は載らない)を
// `devicectl device info apps --include-all-apps`(bundle ID と `url` = インストール先)で引き直す。
//
// 実測 2026-09-24(iPhone SE3・iOS 26): どちらも 0.6 秒前後。apps は 71 件すべてに url が付く。
// 設定アプリを開いた状態で候補 14 件のうち `/appstate` が前面と答えたのは Preferences と SpringBoard
// だけ = シミュレータと同じ「除外してちょうど1つ」の規則がそのまま効く。

import FTCore
import Foundation

public enum IOSPhysicalRunningApps {
    /// 起動中アプリの bundle ID(順序は processes の出力順・重複なし)。devicectl が失敗すれば空。
    /// **apps は呼び手が控えを渡す**(インストール済みの一覧は滅多に変わらないので毎回払わない)
    public static func running(udid: String, apps: [IOSPhysicalAppCatalog.App]) -> [String] {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-devicectl-processes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let result = try? Shell.run(
                ["xcrun", "devicectl", "device", "info", "processes", "--device", udid,
                 "--json-output", outputURL.path], timeout: 30),
              result.status == 0,
              let data = try? Data(contentsOf: outputURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return bundleIDs(apps: apps, processesJSON: json)
    }

    /// 純粋関数(実機無しでテストできる)。processes の各 `executable` を apps の `url` の前方一致で引く。
    /// **アプリ本体のプロセスだけ**を採る —— `url` の直下に実行ファイルがある形
    /// (`<url><Name>`)に限り、`<url>PlugIns/<X>.appex/<X>` のような拡張(ウィジェット・
    /// ビューサービス)は落とす。拡張は利用者から見れば「アプリ」ではなく、前面と答えることがある
    /// (FrontmostApp.isExcluded の chrono と同型)
    static func bundleIDs(apps: [IOSPhysicalAppCatalog.App], processesJSON json: [String: Any]) -> [String] {
        guard let processes = (json["result"] as? [String: Any])?["runningProcesses"] as? [[String: Any]] else {
            return []
        }
        let byURL = apps.compactMap { app in app.url.map { ($0, app.id) } }
        var seen = Set<String>()
        var result: [String] = []
        for process in processes {
            guard let executable = process["executable"] as? String else { continue }
            for (url, bundleID) in byURL where executable.hasPrefix(url) {
                let rest = executable.dropFirst(url.count)
                guard !rest.isEmpty, !rest.contains("/") else { continue }
                if seen.insert(bundleID).inserted { result.append(bundleID) }
            }
        }
        return result
    }
}
