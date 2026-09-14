// アプリの UI フレームワークを問い合わせる**唯一の口**。判定を呼び手ごとに持つと同じアプリで答えが割れる
// (実際に割れていた: in-app の自己申告と .app のマーカーで規則が違い、engine で答えが変わった)。
//
// 答える順(最初に答えが出たところで止まる):
//   静的 ① appPath(.app / .ipa)のマーカー(AppBundleInspector)。**そのパッケージが対象の bundle ID の
//          ものであるときだけ**(プロファイルのアプリとシナリオの対象アプリは別になりうる)
//        ② シミュレータに入っているバンドル(simctl get_app_container。アプリの起動は要らない。実機は不可)
//        ③ 台帳(AppFrameworkLedger = 以前に①②で判定した結果。材料の無い物理端末の唯一の静的な答え)
//   動的 ④ 動いているアプリの自己申告(in-app ブリッジの /status uiFramework。xcuitest・Android は申告しない)
//   どれも無ければ .unknown。**不明を既定値で埋めない**(uikit に倒すと自前描画アプリで空打ちが要るのに
//   撃たず、compose/flutter に倒すと RN で空打ちが行を押す)。
//
// 静的を先に置くのは、自己申告の規則(InAppBridge.uiFramework)が `compose-resources` しか見ず、
// リソースを使わない Compose アプリを uikit と申告するため。**動的な答えは台帳にも memo にも入れない**
// (弱い規則の答えで材料由来の答えを上書きしない)。Android は判定しない(.unknown)。

import Foundation

/// iOS アプリの UI フレームワーク。rawValue は /status の `uiFramework` と台帳の `framework` の文字列。
/// React Native・SwiftUI は `uikit`(a11y 要素がビューを持つ = 自前描画ではない)
public enum AppUIFramework: String, Codable, Sendable, CaseIterable {
    case compose, flutter, uikit

    /// 自前描画(a11y 要素がビューを持たず、タッチはホストのビューが自前で処理する)
    public var isSelfRendered: Bool { self == .compose || self == .flutter }
}

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
        /// "ios" / "android"(ios 以外は常に .unknown)
        public var platform: String
        public var bundleID: String?
        /// ビルド済みの .app / .ipa(プロファイルの appPath / appPathPhysical・ft_install したもの)
        public var appPath: String?
        /// シミュレータの UDID。physical・"booted"(台が複数だと宛先が曖昧)では simctl を撃たない
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
        guard subject.platform == "ios" else { return .unknown }
        let bundleID = subject.bundleID.flatMap { $0.isEmpty ? nil : $0 }
        if let appPath = subject.appPath, let framework = packageFramework(path: appPath, bundleID: bundleID) {
            let answer = AppUIFrameworkAnswer.known(framework, source: .package)
            if let bundleID { remember(answer, for: bundleID) }
            return answer
        }
        guard let bundleID else { return .unknown }
        // 同じプロセスで一度静的に決まったら使い回す(InAppDriver は appPath を持たないので、
        // 無いと simctl を毎シナリオ払う。**版が変わってもフレームワークは変わらない**前提は台帳と同じ)
        if let remembered = remembered(for: bundleID) { return remembered }
        if let udid = subject.udid, !subject.physical, !udid.isEmpty, udid != "booted",
           let framework = installedBundleFramework(bundleID: bundleID, udid: udid) {
            let answer = AppUIFrameworkAnswer.known(framework, source: .installedBundle)
            remember(answer, for: bundleID)
            return answer
        }
        if let entry = AppFrameworkLedger.load(bundleID: bundleID), ledgerEntryIsTrusted(entry, bundleID: bundleID),
           let framework = AppUIFramework(rawValue: entry.framework) {
            return .known(framework, source: .ledger)
        }
        return .unknown
    }

    /// パッケージ由来で bundle ID を確かめていない控えは使わない(sourceBundleID の doc)。
    /// sourcePath の無い控えは simctl で bundle ID から引いた答えなので確かめるまでもない
    static func ledgerEntryIsTrusted(_ entry: AppFrameworkLedger.Entry, bundleID: String) -> Bool {
        entry.sourceBundleID == bundleID || entry.sourcePath == nil
    }

    /// 静的 → 動的 → 不明。`bridgeReport` は**静的に決まらなかったときだけ**呼ぶ
    /// (ブリッジへの往復を静的に決まる回で払わない)。申告が対象アプリのものかは呼び手が
    /// `bridgeReport(_:about:)` で確かめて渡す
    public static func resolve(_ subject: Subject,
                               bridgeReport: () async -> String?) async -> AppUIFrameworkAnswer {
        guard subject.platform == "ios" else { return .unknown }
        let answer = staticAnswer(for: subject)
        guard answer == .unknown else { return answer }
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

    // MARK: - ① パッケージ

    /// 開けない・別アプリのパッケージは nil。台帳に同じ材料(パス・mtime・大きさ)の控えがあれば読まない
    /// (.ipa は開くだけで unzip の一覧を払うので、控えの照合を開くより先に置く)
    static func packageFramework(path: String, bundleID: String?) -> AppUIFramework? {
        let fingerprint = AppFrameworkLedger.fingerprint(path: path)
        if let bundleID, let fingerprint, let cached = AppFrameworkLedger.load(bundleID: bundleID),
           cached.sourceBundleID == bundleID, cached.sourcePath == path,
           cached.sourceModified == fingerprint.modified, cached.sourceSize == fingerprint.size,
           let framework = AppUIFramework(rawValue: cached.framework) {
            return framework
        }
        guard let reader = AppPackageReader.open(path: path) else { return nil }
        // 宣言が無い(読めない)パッケージは照合できないので受け入れる。宣言が違えば別アプリ
        if let bundleID, let declared = reader.infoPlist?["CFBundleIdentifier"] as? String,
           !declared.isEmpty, declared != bundleID {
            return nil
        }
        let framework = AppBundleInspector.detect(in: reader)
        if let bundleID {
            AppFrameworkLedger.store(bundleID: bundleID, entry: .init(
                framework: framework.rawValue, sourcePath: path,
                sourceModified: fingerprint?.modified, sourceSize: fingerprint?.size,
                sourceBundleID: bundleID))
        }
        return framework
    }

    // MARK: - ② シミュレータに入っているバンドル

    /// simctl は 1 回 約 0.45 秒(2026-09-14 実測)。前回引いた置き場の控えがこの台のもので指紋も同じなら撃たない
    static func installedBundleFramework(bundleID: String, udid: String) -> AppUIFramework? {
        if let entry = AppFrameworkLedger.load(bundleID: bundleID),
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
        AppFrameworkLedger.store(bundleID: bundleID, entry: .init(
            framework: framework.rawValue, sourcePath: path,
            sourceModified: fingerprint?.modified, sourceSize: fingerprint?.size,
            sourceBundleID: bundleID))
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

    // MARK: - プロセス内の控え(静的な答えだけ)

    private static let memoLock = NSLock()
    private static var memo: [String: AppUIFrameworkAnswer] = [:]

    private static func remember(_ answer: AppUIFrameworkAnswer, for bundleID: String) {
        memoLock.lock()
        memo[bundleID] = answer
        memoLock.unlock()
    }

    private static func remembered(for bundleID: String) -> AppUIFrameworkAnswer? {
        memoLock.lock()
        defer { memoLock.unlock() }
        return memo[bundleID]
    }

    static func forgetRememberedAnswers() {
        memoLock.lock()
        memo.removeAll()
        memoLock.unlock()
    }
}
