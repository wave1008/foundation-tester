// engine=xcuitest ではブリッジが uiFramework を自己申告しない(InAppBridge だけが持つ /status
// フィールド)ため、ホスト側がパッケージのマーカーから同じ判定をする。マーカー規則は
// InAppBridge.uiFramework(InAppBridge/Sources/InAppBridge.swift:32-42)と同一 — 片方だけ変えない。
// in-app/hybrid は probe の自己申告(probeStatus?.uiFramework)をそのまま使うのでここを呼ばない。
//
// 判定の材料は .app / .ipa(AppPackageReader)。**材料が無いときは台帳**(AppFrameworkLedger =
// 以前に同じ bundle ID を判定した結果)、それも無ければ nil(不明)。不明のとき呼び手
// (StepExecutor.shouldEmptyDrag)は**空打ちを撃たない** —— 打って外れると行やボタンが押されて
// アプリの状態が黙って変わるが、打たずに外れるとタップが吸われて失敗として見える。
// 2026-09-12 に既定を反転した(それまでは「不明なら打つ」)。

import Foundation

public enum AppBundleInspector {
    /// Compose Multiplatform の実行ファイル(デバッグでは `<exe>.debug.dylib`)に必ず入る ObjC クラス名
    /// (Skiko の描画ビュー。実行時に名前で登録されるので記号を削っても残る)。
    /// `compose-resources` フォルダはリソースの仕組みが作るもので、リソースを使わないアプリには無い
    static let composeBinaryMarker = "SkikoUIView"

    /// バンドル直下のマーカー実在から判定する純粋関数(単体テスト対象。プロセス起動は分離)。
    /// 優先順位は InAppBridge と同じ(compose を先に見る)
    public static func uiFramework(composeResourcesExists: Bool, flutterFrameworkExists: Bool) -> String {
        if composeResourcesExists { return "compose" }
        if flutterFrameworkExists { return "flutter" }
        return "uikit"
    }

    /// ビルド済みの .app / .ipa から直接判定する(サブプロセスは .ipa の unzip だけ)。
    /// パス未指定・実在しないパスは nil
    public static func detect(appPath: String?) -> String? {
        guard let reader = AppPackageReader.open(path: appPath) else { return nil }
        return detect(in: reader)
    }

    static func detect(in reader: AppPackageReader) -> String {
        let compose = reader.exists("compose-resources") || composeMarkerPresent(in: reader)
        return uiFramework(composeResourcesExists: compose,
                           flutterFrameworkExists: reader.exists("Frameworks/Flutter.framework"))
    }

    /// 実行ファイルと `*.debug.dylib`(Xcode のデバッグビルドは本体をこちらに置く)のどれかに
    /// Compose のクラス名があるか
    static func composeMarkerPresent(in reader: AppPackageReader) -> Bool {
        var candidates = reader.rootEntries().filter { $0.hasSuffix(".debug.dylib") }
        if let executable = reader.infoPlist?["CFBundleExecutable"] as? String, !executable.isEmpty {
            candidates.insert(executable, at: 0)
        }
        return candidates.contains { reader.contains(composeBinaryMarker, in: $0) == true }
    }

    /// Info.plist の `CFBundleSupportedPlatforms` から「実機用ビルドか」を返す純粋関数。
    /// iphoneos SDK は ["iPhoneOS"]、シミュレータ SDK は ["iPhoneSimulator"](Xcode 27 で実測)。
    /// 空・欠落は nil(= 判らない。呼び手は「鳴らす」側へ倒す)
    public static func isDeviceBuild(supportedPlatforms: [String]?) -> Bool? {
        guard let supportedPlatforms, !supportedPlatforms.isEmpty else { return nil }
        return supportedPlatforms.contains { $0.caseInsensitiveCompare("iPhoneOS") == .orderedSame }
    }

    /// ビルド済み .app / .ipa の Info.plist を読んで isDeviceBuild を当てる(パス未指定・読めない = nil)
    public static func declaresDevicePlatform(appPath: String?) -> Bool? {
        guard let info = AppPackageReader.open(path: appPath)?.infoPlist else { return nil }
        return isDeviceBuild(supportedPlatforms: info["CFBundleSupportedPlatforms"] as? [String])
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

    /// ビルド済み .app / .ipa から `iconNameCandidates` を読む(パス未指定・Info.plist が読めない = 空)。
    /// ローカライズは `<lang>.lproj/InfoPlist.strings` と、文字列カタログのビルドが置く
    /// `InfoPlist.loctable`(言語 → キー → 値)の両方を見る
    public static func iconNameCandidates(appPath: String?) -> [String] {
        guard let reader = AppPackageReader.open(path: appPath), let info = reader.infoPlist else { return [] }
        var localized: [[String: Any]] = []
        for entry in reader.rootEntries().sorted() where entry.hasSuffix(".lproj") {
            if let dict = reader.plist(entry + "/InfoPlist.strings") { localized.append(dict) }
        }
        if let table = reader.plist("InfoPlist.loctable") {
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

    /// 判定できる手段を**安い順に**当て、判定できたら台帳へ覚える(AppFrameworkLedger)。
    ///   ① appPath(.app / .ipa)—— 台帳に同じ材料(パス・mtime・大きさ)の控えがあれば読まずに使う
    ///   ② シミュレータに入っているバンドル(simctl。実機は不可)
    ///   ③ 台帳(以前に同じ bundle ID を判定した結果。材料が手元に無い実機の唯一の答え)
    ///   どれも無ければ nil = 不明(呼び手は空打ちを撃たない)。
    ///
    /// **ブリッジの自己申告が取れなかったときの受け皿**として使うこと。
    /// in-app/hybrid は起動時プローブの `uiFramework` を使うが、あの締切(4秒)は
    /// 「suspend したアプリは TCP を受けても答えない」を素早く諦めるための値で、
    /// **実機の冷えたブリッジが収まる保証は無い**。パッケージのマーカーはデバイスの応答を
    /// 必要としないので、締切に判断を預けずに済む
    public static func detect(appPath: String?, udid: String?, bundleID: String,
                              physical: Bool) -> String? {
        if let appPath, let reader = AppPackageReader.open(path: appPath) {
            let fingerprint = AppFrameworkLedger.fingerprint(path: appPath)
            if let cached = AppFrameworkLedger.load(bundleID: bundleID),
               let fingerprint, cached.sourcePath == appPath,
               cached.sourceModified == fingerprint.modified, cached.sourceSize == fingerprint.size {
                return cached.framework
            }
            let framework = detect(in: reader)
            AppFrameworkLedger.store(bundleID: bundleID, entry: .init(
                framework: framework, sourcePath: appPath,
                sourceModified: fingerprint?.modified, sourceSize: fingerprint?.size))
            return framework
        }
        if let framework = detect(udid: udid, bundleID: bundleID, physical: physical) {
            AppFrameworkLedger.store(bundleID: bundleID, entry: .init(
                framework: framework, sourcePath: nil, sourceModified: nil, sourceSize: nil))
            return framework
        }
        return AppFrameworkLedger.load(bundleID: bundleID)?.framework
    }

    /// Simulator 上のインストール済みアプリのバンドルを調べて uiFramework を返す。
    /// **コマンド失敗・実機・udid 不明は nil**(呼び出し側は「不明」として扱う)
    public static func detect(udid: String?, bundleID: String, physical: Bool) -> String? {
        guard !physical, let udid, !udid.isEmpty else { return nil }
        guard let result = try? Shell.run(
            ["xcrun", "simctl", "get_app_container", udid, bundleID, "app"], timeout: 10),
            result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let reader = AppPackageReader.open(path: path) else { return nil }
        return detect(in: reader)
    }
}
