// テスト開始時に WebView を揃える。
//
// **なぜ要るか**(実測): WebView 124 と 150 で **同じ要素の表現が入れ替わる**
// (124 = placeholder あり / id なし、150 = id あり / placeholder なし)。
// 混在したフリートでは同じシナリオが端末によって落ちる。実際に1台だけ更新した状態で
// E2E を回して `placeholder=…` が**その端末でだけ**「セレクタが見つからない」で落ちた。
//
// **`adb` に「更新する」コマンドは無い**(実測: `cmd webviewupdate` にあるのは
// `set-webview-implementation` と multiprocess の切り替えだけ。`dumpsys webviewupdate` は診断)。
// Play ストア経由の更新は端末任せで起動できない。
//
// **唯一自動化できる経路は「接続中の最も新しい端末から配る」**。実機は Play が勝手に
// 上げるので供給元になりやすい(実測: 実機 150 / エミュレータ 124)。
// **供給元が無ければ何もせず、その旨を伝える**(黙って古いまま走らせない)。

import Foundation
import FTCore

public enum AndroidWebViewUpdate {

    /// 版の比較に使う整数列(`150.0.7871.181` → [150,0,7871,181])
    static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// 左が右より新しいか(純粋)
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = components(lhs), b = components(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 配る計画(純粋)。**供給元は接続中で最も新しい端末**、対象はそれより古い端末。
    /// 供給元が無い / 全部同じなら空(= 何もしない)
    public struct Plan: Equatable {
        public let source: String
        public let sourceVersion: String
        public let targets: [String]
    }

    /// **供給元は接続中の全端末から探し、書き換えるのは run が使う端末だけ**。
    /// 実機は Play が勝手に上げるので供給元になりやすいが、**run のプロファイルに入っていない**
    /// ことが普通で、同じ集合から選ぶと「供給元が居ない」で何も起きなかった(実際に踏んだ)。
    /// 逆に**無関係な端末を書き換えない** —— テスト実行が触っていない端末を変えるのは驚きが大きい
    public static func plan(candidates: [String: String], targets targetSerials: [String]) -> Plan? {
        guard let newest = candidates.max(by: { isNewer($1.value, than: $0.value) }) else { return nil }
        let targets = targetSerials.filter { serial in
            guard let v = candidates[serial] else { return false }
            return isNewer(newest.value, than: v)
        }.sorted()
        guard !targets.isEmpty else { return nil }
        return Plan(source: newest.key, sourceVersion: newest.value, targets: targets)
    }

    /// **自動化できないときに出す文**(純粋)。
    /// **run の対象が揃っているだけのときは黙る**(2026-08-14 に実測で踏んだ) ——
    /// 供給元は繋がっているのに「新しい端末が無い」と言ってしまい、事実と食い違った。
    /// 言うべきなのは「**対象の中に古いものが在るのに、それより新しい端末が1台も無い**」ときだけ
    public static func cannotUpdateMessage(candidates: [String: String], targets: [String]) -> String? {
        let targetVersions = targets.compactMap { candidates[$0] }
        guard let newestTarget = targetVersions.max(by: { isNewer($1, than: $0) }),
              targetVersions.contains(where: { isNewer(newestTarget, than: $0) })
        else { return nil }   // 対象が揃っている = 何も言わない
        guard !candidates.values.contains(where: { isNewer($0, than: newestTarget) }) else { return nil }
        return "fleetest: WebView versions differ but no connected device has a newer build to copy from."
            + " There is no adb command that updates WebView — it ships through the Play Store."
            + " Update one device (Play Store) or connect one that is already newer, then run again."
    }

    /// 吸い出した APK の置き場。**265MB あるので一時ディレクトリには置かない**
    /// (OS に消されると毎回 pull し直す)。**リポジトリにも置かない**(受け手が clone する
    /// ツリーを太らせない)。`SharedResource` と同じ `~/Library/Caches/fleetest` 配下にする。
    /// **版ごとにファイルを分け、古い版は消す**(放置すると 265MB ずつ積み上がる)
    static func cacheDirectory(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent("Library/Caches/fleetest/webview")
    }

    static func cachedAPK(version: String, in directory: URL) -> URL {
        directory.appendingPathComponent("com.google.android.webview-\(version).apk")
    }

}

// MARK: - 配る(デバイスが要るのでここだけ分けてある)

public extension AndroidWebViewUpdate {

    /// 接続中の Android を揃える。供給元が無ければ何もせず理由を言う。
    /// **毎回走らせてよい**(間引かない): 版が揃っていれば `plan` が空で何もせず、
    /// 高い処理(265MB の pull)はキャッシュで1回きり。残るのは版の照会だけで、
    /// 実測 29ms(エミュレータ)/ 94ms(実機)。**間引くと、戻ってしまった端末に気付けない**
    /// **1台の失敗で run を落とさない**(揃わないままでも走れる。落とすのは版差より重い)
    static func run(targets: [String], allSerials: [String],
                    adb: (_ args: [String]) -> String?, log: (String) -> Void) {
        var versions: [String: String] = [:]
        for serial in allSerials {
            guard let text = adb(["-s", serial, "shell", "dumpsys", "package", "com.google.android.webview"]),
                  let v = AndroidWebViewVersions.versionName(inDumpsys: text) else { continue }
            versions[serial] = v
        }
        guard let plan = plan(candidates: versions, targets: targets) else {
            if let message = cannotUpdateMessage(candidates: versions, targets: targets) { log(message) }
            return
        }
        log("==> WebView を \(plan.sourceVersion) へ揃えます(供給元 \(plan.source)・対象 \(plan.targets.count)台)")
        guard let path = adb(["-s", plan.source, "shell", "pm", "path", "com.google.android.webview"])?
            .split(separator: "\n").first.map({ $0.replacingOccurrences(of: "package:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) }), !path.isEmpty else {
            log("⚠️ WebView の APK パスを取れませんでした(揃えずに続行します)")
            return
        }
        let cache = cacheDirectory()
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let local = cachedAPK(version: plan.sourceVersion, in: cache)
        if !FileManager.default.fileExists(atPath: local.path) {
            guard adb(["-s", plan.source, "pull", path, local.path]) != nil else {
                log("⚠️ WebView の APK を取り出せませんでした(揃えずに続行します)")
                return
            }
        }
        for target in plan.targets {
            let result = adb(["-s", target, "install", "-r", local.path]) ?? ""
            if result.contains("Success") { log("✅ \(target): WebView \(plan.sourceVersion)") }
            else { log("⚠️ \(target): WebView を更新できませんでした(揃えずに続行します)") }
        }
        // **古い版は消す**(版ごとに 265MB 積み上がる)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        where name != local.lastPathComponent {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent(name))
        }
    }
}
