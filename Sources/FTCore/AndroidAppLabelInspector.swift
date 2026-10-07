// APK の application-label を aapt / aapt2 の `dump badging` から読む(appName 食い違い警告の材料。
// iOS 側は AppBundleInspector)。FTCore に置くのは RunProfile(FTCore)から呼ぶため
// (FTAndroid は FTCore に依存するので逆向きに呼べない。SDK の探し方は AndroidSDKLocator.findSDKRoot と同順)。
// 読めないもの(aapt 無し・.apks・.aab・失敗)は空 = 判らない = 呼び手は黙る。

import Foundation

public enum AndroidAppLabelInspector {
    /// `dump badging` の出力からラベル候補を返す純粋関数。`application-label:'X'`(既定)を先頭に、
    /// `application-label-ja:'X'` 等のロケール付きを行の順に続ける(重複は除く)。
    /// **ロケール付きも全部候補に入れる** —— 表示は端末の言語で変わるので、どれか1つに一致すれば
    /// 食い違いとしない(iOS の iconNameCandidates と同じ誤検知を出さない側)。空文字のラベルは捨てる
    public static func labelCandidates(badging: String) -> [String] {
        var defaultLabel: String?
        var localized: [String] = []
        for rawLine in badging.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("application-label") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
            // "application-label" 丁度か "application-label-<locale>" だけ(application-label-icon 等は別物の可能性
            // があるが、値が引用符で包まれた文字列でなければ下で落ちる)
            guard key == "application-label" || key.hasPrefix("application-label-") else { continue }
            let rest = line[line.index(after: colon)...]
            guard rest.count >= 2, rest.first == "'", rest.last == "'" else { continue }
            let value = String(rest.dropFirst().dropLast()).replacingOccurrences(of: "\\'", with: "'")
            guard !value.isEmpty else { continue }
            if key == "application-label" {
                if defaultLabel == nil { defaultLabel = value }
            } else if !localized.contains(value) {
                localized.append(value)
            }
        }
        var names: [String] = []
        if let defaultLabel { names.append(defaultLabel) }
        for name in localized where !names.contains(name) { names.append(name) }
        return names
    }

    /// build-tools のディレクトリ名から新しい順に並べる純粋関数(数値の部分で比べる。"34.0.0" > "9.0.0")
    static func newestFirst(_ versions: [String]) -> [String] {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        return versions.sorted { a, b in
            let (pa, pb) = (parts(a), parts(b))
            for i in 0..<max(pa.count, pb.count) {
                let (x, y) = (i < pa.count ? pa[i] : 0, i < pb.count ? pb[i] : 0)
                if x != y { return x > y }
            }
            return a > b
        }
    }

    /// $ANDROID_HOME → $ANDROID_SDK_ROOT → ~/Library/Android/sdk の順の最初の実在ディレクトリ配下で、
    /// 最新の build-tools の aapt2 → aapt。無ければ nil
    static func findAapt(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let fm = FileManager.default
        var roots: [String] = ["ANDROID_HOME", "ANDROID_SDK_ROOT"].compactMap { environment[$0] }
        roots.append(home.appendingPathComponent("Library/Android/sdk").path)
        for root in roots {
            let buildTools = URL(fileURLWithPath: root).appendingPathComponent("build-tools")
            guard let versions = try? fm.contentsOfDirectory(atPath: buildTools.path) else { continue }
            for version in newestFirst(versions) {
                for tool in ["aapt2", "aapt"] {
                    let path = buildTools.appendingPathComponent(version).appendingPathComponent(tool).path
                    if fm.isExecutableFile(atPath: path) { return path }
                }
            }
        }
        return nil
    }

    /// `dump badging` の待ち上限(秒)。APK 1つの読みで通常は 1 秒未満。尽きたときは読めなかったものとして黙る
    static let badgingTimeoutSeconds: Double = 15

    /// APK からラベル候補を読む。.apk 以外・実在しない・aapt 無し・終了コード非ゼロ・期限切れ = 空(判らない)。
    /// 同期でブロックするのでプロファイル解決(協調スレッドプール外の同期経路)からだけ呼ぶ
    public static func labelCandidates(apkPath: String?) -> [String] {
        guard let apkPath, apkPath.lowercased().hasSuffix(".apk"),
              FileManager.default.fileExists(atPath: apkPath),
              let aapt = findAapt() else { return [] }
        guard let result = try? Shell.run([aapt, "dump", "badging", apkPath], timeout: badgingTimeoutSeconds),
              let output = result.outputIfSucceeded else { return [] }
        return labelCandidates(badging: output)
    }
}
