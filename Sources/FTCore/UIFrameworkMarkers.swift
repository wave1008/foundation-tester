// iOS アプリの UI フレームワークをパッケージの目印から決める規則と、その語彙。
// **in-app ブリッジ(自己申告)とホスト(AppBundleInspector)の両方がこのファイルを使う** ——
// InAppBridge/build.sh の SWIFT_SOURCES と BridgeSourceSet.inApp に入っている(片方だけ変えない)。
// 分けて持つと、ホストだけ SkikoUIView を見るようになるなど、同じアプリで答えが割れる。
// このファイルはブリッジにも入るので **FTCore の他の型に依存しない**。変えたらブリッジの版を上げる。
//
// 目印(E2E の SUT 4 つの .app で実測):
//   compose     … `compose-resources`(リソースの仕組みが作る = 使わないアプリには無い)か、
//                 実行ファイルに Skiko の描画ビューのクラス名 `SkikoUIView`(実行時に名前で登録されるので削れない)
//   flutter     … `Frameworks/Flutter.framework`
//   reactNative … `Frameworks/React.framework` / hermes(vm).framework、または実行ファイルに `RCTBridge`
//                 (静的リンクの構成ではフレームワークが無く、クラス名だけが実行ファイルに残る)
//   swiftUI     … 実行ファイルが SwiftUI の `App.main()` を呼ぶ(= `@main struct: App` で起動する)。
//                 **起動の形で決める**ので、UIKit の画面を混ぜていてもこちら・UIHostingController で
//                 SwiftUI を載せた UIKit アプリは uikit
//   uikit       … どれも無い
// 順は compose → flutter → reactNative → swiftUI(CMP の iOS 側の入口は SwiftUI の App なので compose を先に見る)。
// 実行ファイルは `<exe>` と Xcode のデバッグビルドが本体を置く `<exe>.debug.dylib` の両方を見る。

import Foundation

/// アプリの UI フレームワーク。rawValue は /status の `uiFramework` と台帳の `framework` の文字列。
/// iOS は compose / flutter / reactNative / swiftUI / uikit、Android は compose / flutter / reactNative / androidView
public enum AppUIFramework: String, Codable, Sendable, CaseIterable {
    case compose, flutter, reactNative, swiftUI, uikit, androidView

    /// 自前描画(a11y 要素がネイティブのビューを持たず、タッチはホストのビューが自前で処理する)
    public var isSelfRendered: Bool { self == .compose || self == .flutter }

    /// in-app の ref タップで activate が不発のとき、整定を待って要素を取り直し activate を撃ち直すか。
    /// 撃ち直しが効いた実測は Compose だけ(画面遷移の直後は activate がまだ配線されていない)。
    /// UIKit / SwiftUI / RN の不発は恒常的(RN の Pressable・表のセル・入力欄)で、E2E の 9 月の
    /// 約 1.6 万回で一度も効かず、1 回あたり約 0.4 秒(整定 + 固定 250ms + 取り直し 2 回)を払うだけだった。
    /// 自前描画で分ける(Flutter は効いた実測が無いが、個別の値で分けると語彙を足した日に黙って外れる)
    public var retriesUnfiredActivate: Bool { isSelfRendered }

    /// in-app の ref タップで activate が不発のとき、合成タッチを撃たず 501 を返すか(ホストが XCUITest へ回す)。
    /// **SwiftUI の a11y ノード(UIView でない)だけ**: 合成タッチで Button / onTapGesture が発火しない。
    /// SwiftUI のアプリの中でも **UIView の要素**(`.alert` の実体の UIAlertController のボタン・
    /// UIViewRepresentable の UIKit 部品)は合成タッチが効き、XCUITest へ回すとランナーが「アラートが手前」で
    /// 断るので対象外(E2E-iOS / E2EX-iOS のダイアログで退行した)。UIKit・RN・自前描画も対象外
    public func rejectsSyntheticTap(nodeIsView: Bool) -> Bool { self == .swiftUI && !nodeIsView }
}

/// in-app の contentOffset 経路が、指の払いの終わりを知らせる delegate 通知(WillBeginDragging /
/// WillEndDragging / DidEndDragging)を合成してよい相手か。**アプリ自身の delegate だけ**:
/// SwiftUI の ScrollView は内部クラスが delegate で、合成の通知で内部状態を乱さない(従来どおり offset だけ)。
/// WKScrollView の delegate は WebKit 内部で、同じ理由で呼ばない。delegate が無ければ呼ぶ相手もいない
public enum ScrollDelegateNotification {
    /// Swift クラス名は公開型が `SwiftUI.X`、非公開・ジェネリックが `_TtC7SwiftUI…` / `_TtGC7SwiftUI…` /
    /// `_TtCC7SwiftUI…` で出る。アプリ名に SwiftUI を含むだけの型を巻き込まないよう接頭辞で見る
    static let swiftUIClassPrefixes = ["SwiftUI.", "_TtC7SwiftUI", "_TtGC7SwiftUI", "_TtCC7SwiftUI"]
    static let webKitScrollViewClass = "WKScrollView"

    public static func shouldNotify(delegateClassName: String?, scrollViewClassName: String) -> Bool {
        guard let delegateClassName else { return false }
        if scrollViewClassName == webKitScrollViewClass { return false }
        return !swiftUIClassPrefixes.contains { delegateClassName.hasPrefix($0) }
    }
}

public enum UIFrameworkMarkers {
    /// 規則の版。**目印・順序を変えたら上げる**(台帳の控えは版が違えば使わない = 古い規則の答えを返さない)
    public static let rulesVersion = 2

    static let composeResources = "compose-resources"
    static let composeBinaryClass = "SkikoUIView"
    static let flutterFramework = "Frameworks/Flutter.framework"
    static let reactFrameworks = ["Frameworks/React.framework", "Frameworks/hermes.framework",
                                  "Frameworks/hermesvm.framework"]
    static let reactBinaryClass = "RCTBridge"
    /// `SwiftUI.App.main()` の mangled 名(`$s` を除く)。呼び出し側は外部シンボルとして名前を持つ
    static let swiftUIAppEntrySymbol = "7SwiftUI3AppPAAE4mainyyFZ"

    static let binaryNeedles = [composeBinaryClass, reactBinaryClass, swiftUIAppEntrySymbol]

    /// executable: Info.plist の CFBundleExecutable / rootEntries: バンドル直下の名前 /
    /// exists: バンドル直下からの相対パスの実在 / contents: 相対パスの中身(実行ファイルを読むのは要るときだけ・各1回)
    public static func iosFramework(executable: String?, rootEntries: [String],
                                    exists: (String) -> Bool, contents: (String) -> Data?) -> AppUIFramework {
        var present: Set<String>?
        func binaryContains(_ needle: String) -> Bool {
            if present == nil {
                var names = rootEntries.filter { $0.hasSuffix(".debug.dylib") }.sorted()
                if let executable, !executable.isEmpty { names.insert(executable, at: 0) }
                present = presentNeedles(binaryNeedles, in: names.compactMap(contents))
            }
            return present!.contains(needle)
        }
        if exists(composeResources) || binaryContains(composeBinaryClass) { return .compose }
        if exists(flutterFramework) { return .flutter }
        if reactFrameworks.contains(where: exists) || binaryContains(reactBinaryClass) { return .reactNative }
        if binaryContains(swiftUIAppEntrySymbol) { return .swiftUI }
        return .uikit
    }

    /// 目印を**1 語 1 スレッドで並列に**探す(目印の無い UIKit アプリは 3 語とも全走査になる)。
    /// 実測(release・7 回の中央値): 実物の Mach-O(swift-frontend 173 MB)で逐次 142 ms → 並列 66 ms、
    /// E2E-RN の実行ファイル 6 MB で 4.3 → 2.0 ms。1 回の走査で 3 語を照合する形は 129 ms で縮まない
    /// (Data.range(of:) の走査のほうが Swift のバイト単位ループより速い)
    static func presentNeedles(_ needles: [String], in binaries: [Data]) -> Set<String> {
        let hits = HitSlots(count: needles.count)
        DispatchQueue.concurrentPerform(iterations: needles.count) { index in
            let pattern = Data(needles[index].utf8)
            hits.set(index, binaries.contains { $0.range(of: pattern) != nil })
        }
        let found = hits.values
        return Set(needles.indices.filter { found[$0] }.map { needles[$0] })
    }
}

/// `presentNeedles` の並列の書き込み先。**このファイルは in-app ブリッジの dylib にも単体で
/// コンパイルされる**(InAppBridge/build.sh)ので FTCore の他の型(LockedValue)を使わない。
/// @unchecked の根拠 = `slots` は lock の下でしか触らない
private final class HitSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Bool]
    init(count: Int) { slots = [Bool](repeating: false, count: count) }
    func set(_ index: Int, _ hit: Bool) { lock.withLock { slots[index] = hit } }
    var values: [Bool] { lock.withLock { slots } }
}
