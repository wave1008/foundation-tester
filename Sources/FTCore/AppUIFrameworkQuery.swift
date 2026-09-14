// アプリの UI フレームワークを問い合わせる**唯一の口**。判定を呼び手ごとに持つと同じアプリで答えが割れる
// (実際に割れていた: in-app の自己申告と .app のマーカーで規則が違い、engine で答えが変わった)。
// 語彙は AppUIFramework、目印の規則は iOS = UIFrameworkMarkers(in-app ブリッジと共有)/ Android = AndroidPackageInspector。
//
// 答える順(最初に答えが出たところで止まる):
//   静的 ① appPath(.app / .ipa / .apk)の目印。**そのパッケージが対象の bundle ID(パッケージ名)のもので
//          あるときだけ**(プロファイルのアプリとシナリオの対象アプリは別になりうる)
//        ② シミュレータに入っているバンドル(simctl get_app_container。アプリの起動は要らない。iOS のシミュレータだけ)
//        ③ 台帳(AppFrameworkLedger = 以前に①②で判定した結果。材料の無い物理端末の唯一の静的な答え)
//   動的 ④ 動いているアプリの自己申告(in-app ブリッジの /status uiFramework。xcuitest・Android は申告しない)
//   どれも無ければ .unknown。**不明を既定値で埋めない**(uikit に倒すと自前描画アプリで空打ちが要るのに
//   撃たず、compose/flutter に倒すと RN で空打ちが行を押す)。
//
// 静的を先に置くのは、アプリを動かさずに決まり、in-app ブリッジが古い版(規則が弱い)でも答えが変わらないため。
// **動的な答えは台帳にも memo にも入れない**。台帳の控えは規則の版(rules)と確かめた bundle ID が
// 今と一致するときだけ使う。

import Foundation

public enum AppUIFrameworkSource: String, Sendable, CaseIterable {
    case package, installedBundle, ledger, bridgeReport

    /// アプリを動かさずに決まった答えか
    public var isStatic: Bool { self != .bridgeReport }
}

public enum AppUIFrameworkAnswer: Equatable, Sendable {
    case known(AppUIFramework, source: AppUIFrameworkSource)
    case unknown

    public var framework: AppUIFramework? {
        if case .known(let framework, _) = self { return framework }
        return nil
    }

    public var source: AppUIFrameworkSource? {
        if case .known(_, let source) = self { return source }
        return nil
    }
}

public enum AppUIFrameworkQuery {
    public struct Subject: Equatable, Sendable {
        /// "ios" / "android"(それ以外は常に .unknown)
        public var platform: String
        /// iOS の bundle ID / Android のパッケージ名
        public var bundleID: String?
        /// ビルド済みの .app / .ipa / .apk(プロファイルの appPath / appPathPhysical・ft_install したもの)
        public var appPath: String?
        /// シミュレータの UDID。physical・"booted"(台が複数だと宛先が曖昧)・Android では simctl を撃たない
        public var udid: String?
        public var physical: Bool

        public init(platform: String, bundleID: String?, appPath: String?, udid: String?, physical: Bool) {
            self.platform = platform
            self.bundleID = bundleID
            self.appPath = appPath
            self.udid = udid
            self.physical = physical
        }
    }

    /// 静的な材料(①②③)だけで答える。ブリッジには問い合わせない
    public static func staticAnswer(for subject: Subject) -> AppUIFrameworkAnswer {
        let platform = subject.platform
        guard let rules = rulesVersion(platform: platform) else { return .unknown }
        let bundleID = subject.bundleID.flatMap { $0.isEmpty ? nil : $0 }
        if let appPath = subject.appPath,
           let framework = packageFramework(path: appPath, bundleID: bundleID, platform: platform, rules: rules) {
            let answer = AppUIFrameworkAnswer.known(framework, source: .package)
            if let bundleID { remember(answer, for: bundleID, platform: platform) }
            return answer
        }
        guard let bundleID else { return .unknown }
        // 同じプロセスで一度静的に決まったら使い回す(InAppDriver・SessionRecoveryDriver は appPath を持たないので、
        // 無いと simctl を毎シナリオ払う。**版が変わってもフレームワークは変わらない**前提は台帳と同じ)
        if let remembered = remembered(for: bundleID, platform: platform) { return remembered }
        if platform == "ios", let udid = subject.udid, !subject.physical, !udid.isEmpty, udid != "booted",
           let framework = installedBundleFramework(bundleID: bundleID, udid: udid) {
            let answer = AppUIFrameworkAnswer.known(framework, source: .installedBundle)
            remember(answer, for: bundleID, platform: platform)
            return answer
        }
        if let entry = AppFrameworkLedger.load(bundleID: bundleID, platform: platform),
           ledgerEntryIsTrusted(entry, bundleID: bundleID, rules: rules),
           let framework = AppUIFramework(rawValue: entry.framework) {
            return .known(framework, source: .ledger)
        }
        return .unknown
    }

    /// 静的 → 動的 → 不明。`bridgeReport` は**静的に決まらなかったときだけ**呼ぶ
    /// (ブリッジへの往復を静的に決まる回で払わない)。申告が対象アプリのものかは呼び手が
    /// `bridgeReport(_:about:)` で確かめて渡す。Android は申告が無いので静的な答えだけ
    public static func resolve(_ subject: Subject,
                               bridgeReport: () async -> String?) async -> AppUIFrameworkAnswer {
        let answer = staticAnswer(for: subject)
        guard answer == .unknown, subject.platform == "ios" else { return answer }
        if let raw = await bridgeReport(), let framework = AppUIFramework(rawValue: raw) {
            return .known(framework, source: .bridgeReport)
        }
        return .unknown
    }

    /// in-app ブリッジの自己申告を、**申告が `bundleID` のアプリについてのもののときだけ**返す。
    /// in-app ブリッジは注入先アプリのプロセスに住むので、対象アプリと注入先が違う run では
    /// 別アプリの申告になる(bundleID が nil = 照合できない → 返さない)
    public static func bridgeReport(_ status: StatusResponse?, about bundleID: String?) -> String? {
        guard let status, let raw = status.uiFramework,
              let bundleID, let session = status.sessionBundleID, session == bundleID else { return nil }
        return raw
    }

    /// 掴んだ要素が自前描画のホストに属するか。アプリの答えが出ていればそれ、不明なら要素のクラス名
    /// (AccessibilityClassHint。UIKit の実アプリにも少数出るので要素単位でしか使わない)、
    /// それも無ければ nil(不明。呼び手は撃たない側へ倒す)
    public static func hostsOwnTouches(_ element: ElementInfo, app: AppUIFramework?) -> Bool? {
        if let app { return app.isSelfRendered }
        return AccessibilityClassHint.hostsOwnTouches(element)
    }

    /// その OS の目印の規則の版(判定しない OS は nil)
    static func rulesVersion(platform: String) -> Int? {
        switch platform {
        case "ios": return UIFrameworkMarkers.rulesVersion
        case "android": return AndroidPackageInspector.rulesVersion
        default: return nil
        }
    }

    /// 今の規則で、この bundle ID のものだと確かめて書いた控えだけを使う(Entry.sourceBundleID / rules の doc)
    static func ledgerEntryIsTrusted(_ entry: AppFrameworkLedger.Entry, bundleID: String, rules: Int) -> Bool {
        entry.rules == rules && entry.sourceBundleID == bundleID
    }

    // MARK: - ① パッケージ

    /// 開けない・別アプリのパッケージは nil。台帳に同じ材料(パス・mtime・大きさ)の控えがあれば読まない
    /// (.ipa / .apk は開くだけで unzip の一覧を払うので、控えの照合を開くより先に置く)
    static func packageFramework(path: String, bundleID: String?, platform: String, rules: Int) -> AppUIFramework? {
        let fingerprint = AppFrameworkLedger.fingerprint(path: path)
        if let bundleID, let fingerprint, let cached = AppFrameworkLedger.load(bundleID: bundleID, platform: platform),
           ledgerEntryIsTrusted(cached, bundleID: bundleID, rules: rules), cached.sourcePath == path,
           cached.sourceModified == fingerprint.modified, cached.sourceSize == fingerprint.size,
           let framework = AppUIFramework(rawValue: cached.framework) {
            return framework
        }
        guard let reader = AppPackageReader.open(path: path) else { return nil }
        let declared: String?
        let framework: AppUIFramework
        switch platform {
        case "android":
            guard (path as NSString).pathExtension.lowercased() == "apk" else { return nil }
            declared = AndroidPackageInspector.packageName(in: reader)
            framework = AndroidPackageInspector.detect(in: reader)
        default:
            guard (path as NSString).pathExtension.lowercased() != "apk" else { return nil }
            declared = reader.infoPlist?["CFBundleIdentifier"] as? String
            framework = AppBundleInspector.detect(in: reader)
        }
        // 宣言が無い(読めない)パッケージは照合できないので受け入れる。宣言が違えば別アプリ
        if let bundleID, let declared, !declared.isEmpty, declared != bundleID { return nil }
        if let bundleID {
            AppFrameworkLedger.store(bundleID: bundleID, platform: platform, entry: .init(
                framework: framework.rawValue, sourcePath: path,
                sourceModified: fingerprint?.modified, sourceSize: fingerprint?.size,
                sourceBundleID: bundleID, rules: rules))
        }
        return framework
    }

    // MARK: - ② シミュレータに入っているバンドル

    /// simctl は 1 回 約 0.45 秒(2026-09-14 実測)。前回引いた置き場の控えがこの台のもので指紋も同じなら撃たない
    static func installedBundleFramework(bundleID: String, udid: String) -> AppUIFramework? {
        let rules = UIFrameworkMarkers.rulesVersion
        if let entry = AppFrameworkLedger.load(bundleID: bundleID, platform: "ios"),
           ledgerEntryIsTrusted(entry, bundleID: bundleID, rules: rules),
           let framework = installedBundleCacheHit(entry: entry, udid: udid,
                                                   fingerprint: entry.sourcePath.flatMap(AppFrameworkLedger.fingerprint)) {
            return framework
        }
        guard let result = try? Shell.run(
            ["xcrun", "simctl", "get_app_container", udid, bundleID, "app"], timeout: 10),
            result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let reader = AppPackageReader.open(path: path) else { return nil }
        let framework = AppBundleInspector.detect(in: reader)
        let fingerprint = AppFrameworkLedger.fingerprint(path: path)
        AppFrameworkLedger.store(bundleID: bundleID, platform: "ios", entry: .init(
            framework: framework.rawValue, sourcePath: path,
            sourceModified: fingerprint?.modified, sourceSize: fingerprint?.size,
            sourceBundleID: bundleID, rules: rules))
        return framework
    }

    /// 控えが使えるのは、置き場がこの台(`…/Devices/<udid>/…`)の中で指紋が一致するときだけ。
    /// 入れ直すと置き場(Bundle/Application/<UUID>)が変わるので古い控えは実在せず外れる
    static func installedBundleCacheHit(entry: AppFrameworkLedger.Entry, udid: String,
                                        fingerprint: (modified: Double, size: Int)?) -> AppUIFramework? {
        guard let path = entry.sourcePath, path.contains("/Devices/\(udid)/"), let fingerprint,
              entry.sourceModified == fingerprint.modified, entry.sourceSize == fingerprint.size
        else { return nil }
        return AppUIFramework(rawValue: entry.framework)
    }

    // MARK: - プロセス内の控え(静的な答えだけ。鍵は OS + bundle ID)

    private static let memoLock = NSLock()
    private static var memo: [String: AppUIFrameworkAnswer] = [:]

    private static func remember(_ answer: AppUIFrameworkAnswer, for bundleID: String, platform: String) {
        memoLock.lock()
        memo["\(platform)/\(bundleID)"] = answer
        memoLock.unlock()
    }

    private static func remembered(for bundleID: String, platform: String) -> AppUIFrameworkAnswer? {
        memoLock.lock()
        defer { memoLock.unlock() }
        return memo["\(platform)/\(bundleID)"]
    }

    static func forgetRememberedAnswers() {
        memoLock.lock()
        memo.removeAll()
        memoLock.unlock()
    }
}
