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

    /// Info.plist の `CFBundleSupportedPlatforms` から「実機用ビルドか」を返す純粋関数。
    /// iphoneos SDK は ["iPhoneOS"]、シミュレータ SDK は ["iPhoneSimulator"](Xcode 27 で実測)。
    /// 空・欠落は nil(= 判らない。呼び手は「鳴らす」側へ倒す)
    public static func isDeviceBuild(supportedPlatforms: [String]?) -> Bool? {
        guard let supportedPlatforms, !supportedPlatforms.isEmpty else { return nil }
        return supportedPlatforms.contains { $0.caseInsensitiveCompare("iPhoneOS") == .orderedSame }
    }

    /// ビルド済み .app の Info.plist を読んで isDeviceBuild を当てる(パス未指定・読めない = nil)
    public static func declaresDevicePlatform(appPath: String?) -> Bool? {
        guard let appPath else { return nil }
        let plist = (appPath as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any] else { return nil }
        return isDeviceBuild(supportedPlatforms: dict["CFBundleSupportedPlatforms"] as? [String])
    }

    /// ホーム画面のアイコンの下に出る名前の候補を返す純粋関数。
    /// 名前の優先は iOS の表示と同じ(CFBundleDisplayName → CFBundleName)。**ローカライズ値も全部候補に入れる** ——
    /// 表示は端末の言語で変わるので、どれか1つに一致すれば食い違いとしない(誤検知を出さない側に倒す)。
    /// 空 = 判らない(呼び手は黙る)
    public static func iconNameCandidates(infoPlist: [String: Any],
                                          localized: [[String: Any]]) -> [String] {
        func name(_ dict: [String: Any]) -> String? {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = dict[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        var names: [String] = []
        for dict in [infoPlist] + localized {
            if let value = name(dict), !names.contains(value) { names.append(value) }
        }
        return names
    }

    /// ビルド済み .app から `iconNameCandidates` を読む(パス未指定・Info.plist が読めない = 空)。
    /// ローカライズは `<lang>.lproj/InfoPlist.strings` と、文字列カタログのビルドが置く
    /// `InfoPlist.loctable`(言語 → キー → 値)の両方を見る
    public static func iconNameCandidates(appPath: String?) -> [String] {
        guard let appPath, let info = plistDictionary(atPath:
            (appPath as NSString).appendingPathComponent("Info.plist")) else { return [] }
        var localized: [[String: Any]] = []
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: appPath)) ?? []
        for entry in entries.sorted() where entry.hasSuffix(".lproj") {
            let strings = ((appPath as NSString).appendingPathComponent(entry) as NSString)
                .appendingPathComponent("InfoPlist.strings")
            if let dict = plistDictionary(atPath: strings) { localized.append(dict) }
        }
        if let table = plistDictionary(atPath:
            (appPath as NSString).appendingPathComponent("InfoPlist.loctable")) {
            for language in table.keys.sorted() {
                if let dict = table[language] as? [String: Any] { localized.append(dict) }
            }
        }
        return iconNameCandidates(infoPlist: info, localized: localized)
    }

    /// アプリプロファイルの `appName` がアイコン名の候補のどれとも一致しないときの警告(一致・候補が空は nil)。
    /// **appName はアイコン名を兼ねる**: 名前を省いた `tapAppIcon()` はこれとラベルの完全一致で探し
    /// (`AppIconLocator.findIcon`)、システムアラートの題名がこの名前を含まなければ「前の run の残りかも」と
    /// 助言する(`SystemUIGate.mayBeLeftover`)。どちらも食い違うと黙って誤る(2026-09-11: 実機用
    /// プロファイルに「(実機)」を足した appName で tapAppIcon が App icon not found)。止めはしない
    public static func appNameMismatchWarning(appRef: String, platform: String, appName: String,
                                              candidates: [String]) -> String? {
        guard !candidates.isEmpty, !candidates.contains(appName) else { return nil }
        let shown = candidates.map { "\"\($0)\"" }.joined(separator: " / ")
        return "apps/\(appRef).json: \(platform).appName \"\(appName)\" is not the name shown under"
            + " the app icon (\(shown), read from the app bundle at appPath) — tapAppIcon() without"
            + " a name looks for appName on the home screen, and a system alert whose title does not"
            + " name appName is reported as possibly left over from an earlier run."
            + " Set \(platform).appName to the name under the icon"
    }

    /// バイナリ / XML の plist と、`"key" = "value";` 形の .strings の両方を読む
    /// (PropertyListSerialization は旧形式 = .strings も解釈する)
    private static func plistDictionary(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    /// バンドルから判定できる手段を**安い順に**当てる(--app-path → simctl)。
    ///
    /// **ブリッジの自己申告が取れなかったときの受け皿**として使うこと。
    /// in-app/hybrid は起動時プローブの `uiFramework` を使うが、あの締切(4秒)は
    /// 「suspend したアプリは TCP を受けても答えない」を素早く諦めるための値で、
    /// **実機の冷えたブリッジが収まる保証は無い**。外れたときに nil のまま進むと
    /// `StepExecutor.shouldEmptyDrag` が「不明なら打つ」へ倒れ、RN では 4pt の横抜きが
    /// `pressRetentionOffset`(既定20pt)に収まって `onPress` が成立する =
    /// **`scrollTo` しただけで行が選択される**(E2E-RN S0100 で実測した現象)。何も失敗しない。
    /// バンドルのマーカーはデバイスの応答を必要としないので、締切に判断を預けずに済む
    public static func detect(appPath: String?, udid: String?, bundleID: String,
                              physical: Bool) -> String? {
        detect(appPath: appPath) ?? detect(udid: udid, bundleID: bundleID, physical: physical)
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
