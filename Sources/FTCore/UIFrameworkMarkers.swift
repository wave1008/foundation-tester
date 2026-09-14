// iOS アプリの UI フレームワークをパッケージの目印から決める規則と、その語彙。
// **in-app ブリッジ(自己申告)とホスト(AppBundleInspector)の両方がこのファイルを使う** ——
// InAppBridge/build.sh の SWIFT_SOURCES と BridgeSourceSet.inApp に入っている(片方だけ変えない)。
// 規則を分けて持っていた頃は、ホストだけ SkikoUIView を見るようになり、同じアプリで答えが割れた。
// このファイルはブリッジにも入るので **FTCore の他の型に依存しない**。変えたらブリッジの版を上げる。
//
// 目印(2026-09-14 に E2E の SUT 4 つの .app で実測):
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
    /// 実測(2026-09-14・release・7 回の中央値): 実物の Mach-O(swift-frontend 173 MB)で逐次 142 ms → 並列 66 ms、
    /// E2E-RN の実行ファイル 6 MB で 4.3 → 2.0 ms。1 回の走査で 3 語を照合する形は 129 ms で縮まない
    /// (Data.range(of:) の走査のほうが Swift のバイト単位ループより速い)
    static func presentNeedles(_ needles: [String], in binaries: [Data]) -> Set<String> {
        var hits = [Bool](repeating: false, count: needles.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: needles.count) { index in
            let pattern = Data(needles[index].utf8)
            let hit = binaries.contains { $0.range(of: pattern) != nil }
            lock.lock()
            hits[index] = hit
            lock.unlock()
        }
        return Set(needles.indices.filter { hits[$0] }.map { needles[$0] })
    }
}
