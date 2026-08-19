// Android の web コンテンツを DOM(CDP)から読む。**対象は2つ**(2026-08-15 に自作アプリを追加):
// **ブラウザ本体**(2026-08-13〜)と**テスト対象アプリ自身の WebView**。
// どちらを DOM で読むかの判定は `route`(純粋)1箇所。経緯と根拠は docs/design.md
// §ブラウザの中身は DOM から読む / §木はどこから来るか。
//
// **自作アプリの WebView を DOM で読む理由は、ブラウザとは別**(2026-08-15 実測)。
// Android の a11y は WebView の版で属性を**入れ替えて**出す:
//
//   WebView 124 : textField ph="WebView 入力"   (placeholder あり / id なし)
//   WebView 150 : textField id=wv_input          (id あり / placeholder なし)
//
// (記録は `AndroidWebViewVersions.swift` 冒頭)。トレードではなく入れ替えなので、
// **`#id` も `placeholder=` も混在フリートでは移植できない**。DOM から読めば木が両方を持つので、
// **版差が供給源で消える**。ブラウザ側の理由(a11y に本文が出ない)とは無関係なので、
// **門も別**(`route` の宣言参照): ブラウザは a11y が足りていれば読まないが、
// **自作アプリは足りて見えても読む**(問題は「読めているか」ではなく「同じ属性が出るか」)。
//
// **成立条件: アプリが debuggable であること**(2026-08-15 に emulator-5554 /
// `com.ftester.e2e` で実測)。**アプリ側が `setWebContentsDebuggingEnabled(true)` を
// 呼ぶ必要は無い** —— debuggable なら WebView が1つでも生成された時点で devtools ソケットが開く
// (確認した版は Chrome/150.0.7871.181)。**アプリの協力を要る退化を足さない**
// (プロジェクトの決定。release ビルドは id を難読化するので、id で指すテスト自体が
// debug ビルドの活動)。開いていなければ黙って従来の a11y(下の `read` の宣言参照)。
//
// **JS も木への差し込みロジックも iOS と共有する**(`FTCore.WebViewDOM`)。あちらは in-app
// エンジンから WKWebView の a11y が見えない事情で先に入った経路で、返す形(role/label/矩形)も
// 共通なので、**同じ JS を Android で走らせれば木が一致する** = セレクタが同じ書き方で通る。
// 座標写し(`elements`)・WebView 選択(`webViewElement`/`webViewFrame`)・差し込み
// (`droppingWebViewSubtree`)は `FTCore.WebViewDOM` の関数を直接呼ぶ(ここに2つ目を持たない)。
// **density だけがこのファイルの担当**(a11y の bounds が物理 px なので、呼ぶ側で
// `displayDensity()` を渡す。iOS は `density: 1` を渡すだけで同じ関数を使う)。
//
// **経路は CDP**(Chrome DevTools Protocol)。Android のブリッジはアクセシビリティサービスで
// 別プロセスなので、他アプリの WebView に `evaluateJavascript` を撃てない。ホスト側から
// `adb forward localabstract:<socket>` で入る。
//
// **ソケット名の規則が2つある**: アプリ内 WebView は `webview_devtools_remote_<pid>` で
// **pid はアプリ自身の pid**(`adb shell pidof <package>`。実測)。一方
// **Chrome のソケットは `@chrome_devtools_remote` で pid が付かない**(実測)。
// pid 一致規則では届かないので、ブラウザは**パッケージ名 → 固定ソケット名**の別規則を使う
// (`browserSocketName` / `appSocketName` の2本立て。選ぶのは `route`)。
//
// **能動タブの選択が要る**: Chrome は複数タブを開くので `/json` は `type=page` を複数返す
// (実測で7件)。**順序では決まらない**(`/json` は MRU 順ではないと実測。詳細は `rankedTabs`)。
// 確からしい順に並べ、**上から評価を試して応答したものを能動タブとみなす** ——
// 背面タブは Chrome が JS を止めるので返らない。
//
// **木への差し込みは重複させない**: Chrome は簡単なページなら a11y へ本文を普通に公開する
// (example.com で `WebView` ノード + 本文の StaticText/Link が実際に出た)。素朴に DOM を
// append すると同じ本文が二重に並ぶ。**読むと決めたら DOM が web コンテンツ領域の唯一の正**
// —— `WebView` ノードの内側にある a11y 要素を落としてから DOM のノードを入れる
// (`droppingWebViewSubtree`)。ノード自身と外側(ブラウザ chrome の `#url_bar` `#toolbar`、
// 自作アプリのネイティブ UI)は a11y のまま残す。**読むか読まないかの判定は `route` だけ**。
//
// **注入は ref の名前空間が違う**: ブリッジは自分の snapshot の ref しか受け付けない。
// DOM ノードにはホストが新しい ref を振るので、`type`/`clearInput` は `bridgeRefMap` で
// 写してから送る(宣言参照)。
//
// **殺しスイッチは対象ごとに別の口**(どちらも既定オン。1つに束ねない ——
// 束ねると「ブラウザだけ止めて A/B」が取れず、切り分けで効く道具を失う):
//   ブラウザ本体          → `FT_BROWSER_DOM=off`(iOS Safari 側と同じ変数)
//   自作アプリの WebView  → `FT_WEBVIEW_DOM=off`(**iOS in-app 側と同じ変数・同じ意味**
//                            = 「テスト対象アプリの WebView を DOM で読むか」。OS で別名にしない)
//
// **Chrome 側の成立条件は未実測**(ソケット公開条件。実測できた端末では常に見えていた)。
// 取れないときは例外にせず黙って従来の a11y のまま(下の `read` の宣言参照)。

import CryptoKit
import Foundation
import FTCore

public enum AndroidWebViewDOM {

    /// パッケージ名 → CDP ソケット名(pid 不要)。**`com.android.chrome` だけ実測**。
    /// 他チャンネル(beta/dev/canary)はソケット名が同じという確証が無いので**推測で足さない**
    /// (誤った名前を書くより、対象外として a11y へ黙って落ちるほうが安全)。
    private static let browserSockets: [String: String] = [
        "com.android.chrome": "chrome_devtools_remote",
    ]

    /// 対象パッケージのブラウザ用ソケット名。既知集合に無ければ nil(= ブラウザではない)
    public static func browserSocketName(packageID: String) -> String? {
        browserSockets[packageID]
    }

    /// 自作アプリの CDP ソケット名。**pid が付く**(ブラウザの固定名と規則が違う。冒頭参照)。
    /// pid は**アプリ自身の pid**(WebView のレンダラではない)
    public static func appSocketName(pid: Int) -> String { "webview_devtools_remote_\(pid)" }

    // MARK: - どの木を使うか(純粋。デバイスに触る前にここだけで決まる)

    /// DOM を読む経路。ブラウザと自作アプリは**ソケット規則も門も違う**ので型で分ける
    public enum Route: Equatable {
        /// a11y のまま(DOM は読まない)
        case a11y
        /// ブラウザ本体。ソケット名はパッケージ固定で pid を引かなくてよい
        case browser(socket: String)
        /// テスト対象アプリ自身の WebView。ソケットは pid から引く(`resolveAppSocket`)
        case appWebView
    }

    /// **DOM を読むか a11y のままか**(純粋)。
    ///
    /// **門は対象で違う**:
    /// - ブラウザ: **a11y が足りていれば読まない**(a11y は 6〜20 倍速く、木が出来る窓を過ぎれば
    ///   内容は一致する。`WebViewDOM.browserA11yLooksSufficient` の宣言参照)
    /// - 自作アプリ: **a11y の充足度では切り替えない**。足りて見えても版で属性が入れ替わるので
    ///   (冒頭の 124/150 の実測)、問うているのは「読めているか」ではなく「**同じ属性が出るか**」。
    ///   代わりの門は **`webView` ノードの有無**だけ —— 無い画面で pid 引きと forward を払わない
    ///   (ブラウザはこの門を 2026-08-14 に外したが、あれは Chrome が本文非公開の画面で
    ///   ノードごと落とすため。**アプリ自身の WebView は自分の a11y ツリーに出る**ので事情が違う)
    public static func route(packageID: String, hasWebViewNode: Bool, a11yLooksSufficient: Bool,
                             browserDOMEnabled: Bool, appWebViewDOMEnabled: Bool) -> Route {
        if let socket = browserSocketName(packageID: packageID) {
            guard browserDOMEnabled, !a11yLooksSufficient else { return .a11y }
            return .browser(socket: socket)
        }
        guard appWebViewDOMEnabled, hasWebViewNode else { return .a11y }
        return .appWebView
    }

    // MARK: - 自作アプリのソケット解決(pid → ソケット名。純粋部分)

    /// 端末への問い合わせを**1往復に畳む**ための区切り(adb は1回ごとに数十 ms かかり、
    /// ここは毎 snapshot の経路)。前半が `pidof`、後半が `/proc/net/unix` の抜粋
    static let probeMarker = "--ft-sockets--"

    /// pid とソケット一覧をまとめて採る adb 引数(純粋)。
    /// **綴りを検めてから素のシェル文字列へ埋める**(`;` を含むパッケージ名が来たら
    /// 端末上で別コマンドになる)。検めに落ちたら nil = この経路を使わない
    static func probeCommand(packageID: String) -> [String]? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !packageID.isEmpty, packageID.allSatisfy({ allowed.contains($0) }) else { return nil }
        // grep で端末側から絞る(一覧そのものは数百行あり、要るのは devtools の口だけ)
        return ["shell", "pidof \(packageID); echo \(probeMarker); "
                + "cat /proc/net/unix | grep devtools_remote"]
    }

    /// ソケット解決の結果。**`socket` 以外はすべて「a11y のまま」に読み替える**(呼び出し側)
    public enum AppSocketResolution: Equatable {
        case socket(String)
        /// `pidof` が空 = アプリが起きていない
        case appNotRunning
        /// pid はあるがソケットが無い = WebView がまだ生成されていない / debuggable でない
        case noWebView
        /// 候補が複数(同名プロセスが複数 pid で走っている等)。**推測で1つ選ばない** ——
        /// 外すと**別プロセスの DOM を本物の画面として木へ差し込む**(気付けない誤り)
        case ambiguous([String])
        /// 端末へ問い合わせられなかった(adb 失敗)
        case unavailable
    }

    /// `probeCommand` の出力 → ソケット名(純粋)。
    ///
    /// 一覧には**他アプリの `webview_devtools_remote_<別 pid>` も Chrome の
    /// `chrome_devtools_remote` も並ぶ**ので、採るのは**自分の pid と厳密一致する名前だけ**。
    public static func resolveAppSocket(probeOutput: String) -> AppSocketResolution {
        guard let marker = probeOutput.range(of: probeMarker) else { return .unavailable }
        let pids = pidList(String(probeOutput[..<marker.lowerBound]))
        guard !pids.isEmpty else { return .appNotRunning }
        let listing = String(probeOutput[marker.upperBound...])
        let names = Set(devtoolsSockets(inProcNetUnix: listing))
        // **一覧そのものを読めない端末**(`/proc/net/unix` が権限で弾かれる)では pid の規則から
        // 名前を組み立て、実在の判定は続く HTTP に任せる。pid が複数のときは組み立てない
        // (実在を確かめられないまま別プロセスを覗きに行くことになる)
        if names.isEmpty, listingUnreadable(listing) {
            let derived = pids.map { appSocketName(pid: $0) }
            return derived.count == 1 ? .socket(derived[0]) : .ambiguous(derived)
        }
        let matched = pids.map { appSocketName(pid: $0) }.filter { names.contains($0) }
        switch matched.count {
        case 0: return .noWebView
        case 1: return .socket(matched[0])
        default: return .ambiguous(matched.sorted())
        }
    }

    /// `pidof` の出力(空白区切り。同名プロセスが複数返ることがある)。
    /// 数字でない語は落とす(stderr が混ざっても pid と読み違えない)
    static func pidList(_ text: String) -> [Int] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .compactMap { Int($0) }
    }

    /// `/proc/net/unix` の行から**抽象ソケット名**を採る(純粋。先頭の `@` は落とす)。
    /// パス欄は行末なので `@` から行末までが名前。`devtools_remote` を含む行だけ返し、
    /// **どれを使うかは呼び出し側が決める**
    static func devtoolsSockets(inProcNetUnix text: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            guard let at = line.lastIndex(of: "@") else { return nil }
            let name = line[line.index(after: at)...].trimmingCharacters(in: .whitespaces)
            guard name.contains("devtools_remote") else { return nil }
            return name
        }
    }

    /// 一覧を読めなかった形(`Shell` は stderr を stdout へ混ぜるので、失敗も同じ文字列に来る)
    private static func listingUnreadable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("permission denied") || lower.contains("no such file")
            || lower.contains("not permitted")
    }

    /// スキームと `www.` だけを落とした比較用の形。Chrome のアドレス欄はこの2つを隠して出す
    /// (実測: タブ URL `https://www.jma.go.jp/bosai/forecast/` に対し欄の値は
    /// `jma.go.jp/bosai/forecast/`)。**フラグメントはここでは落とさない** ——
    /// 同じページの2タブを分ける唯一の材料がフラグメントのことがあり、
    /// ここで落とすと**区別したい当の差が消えて背面タブと同点になる**
    static func normalizedURL(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s
    }

    /// フラグメントまで落とした形(1段ゆるい一致に使う)
    static func withoutFragment(_ url: String) -> String {
        guard let hash = url.firstIndex(of: "#") else { return url }
        return String(url[..<hash])
    }

    /// CDP の `/json` を**確からしい順**に並べる(純粋)。**1つに決め打ちしない** ——
    /// 呼び出し側が上から順に評価を試し、**応答したものを能動タブとみなす**
    /// (`read` の宣言参照)。
    ///
    /// **`/json` は MRU 順ではない**(2026-08-13 に実測して撤回した。7タブの Chrome で
    /// 先頭は前面ではない別サイトだった)。順序を信じて1つ選ぶと**背面タブを掴む**ことがあり、
    /// **Chrome は背面タブの JS を止めるので評価が返らない**(実測で 183 秒待っても返らなかった)。
    ///
    /// 並べる根拠は強い順に ①アドレス欄の値とタブ URL が一致(スキーム/`www.` だけ正規化)→
    /// ②フラグメントまで落とせば一致 → ③タブ URL がアドレス欄の値を含む → ④タブ title が
    /// a11y の `WebView` ラベルと一致 → ⑤残り。**題名だけでは足りない**(同じページを2タブ開くと
    /// 題名が同じになり、実際にそれで背面タブを選んで固まった)。
    /// about:blank も候補にする。除くのは devtools 自身のページと、ページ以外の型・ソケット欠落だけ
    public static func rankedTabs(webViewLabel: String?, urlBarValue: String?,
                                  targets: [[String: Any]]) -> [String] {
        struct Page { let index: Int; let url: String; let title: String; let socket: String }
        let pages: [Page] = targets.enumerated().compactMap { index, t in
            guard (t["type"] as? String) == "page",
                  let socket = t["webSocketDebuggerUrl"] as? String, !socket.isEmpty else { return nil }
            let url = (t["url"] as? String) ?? ""
            guard !url.hasPrefix("devtools://") else { return nil }
            return Page(index: index, url: url, title: (t["title"] as? String) ?? "", socket: socket)
        }
        let bar = (urlBarValue ?? "").trimmingCharacters(in: .whitespaces)
        let label = (webViewLabel ?? "").trimmingCharacters(in: .whitespaces)
        func rank(_ page: Page) -> Int {
            let url = normalizedURL(page.url)
            let barURL = normalizedURL(bar)
            if !bar.isEmpty, url == barURL { return 0 }
            if !bar.isEmpty, withoutFragment(url) == withoutFragment(barURL) { return 1 }
            if !bar.isEmpty, url.contains(barURL) { return 2 }
            if !label.isEmpty, page.title == label { return 3 }
            return 4
        }
        // 同順位は元の並びを保つ(`sorted` は安定でないので index を第2キーにする)
        return pages.map { (rank($0), $0.index, $0.socket) }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
    }

    /// a11y の `#url_bar` の value(能動タブの手掛かり②。宣言コメント参照)
    public static func urlBarValue(in elements: [ElementInfo]) -> String? {
        elements.first(where: { $0.identifier == "url_bar" })?.value
    }

    /// serial ごとに host 側の forward port を固定(pid が使えないブラウザ経路でも、並列 run で
    /// 別デバイスの forward と衝突しないようにする)。SHA256 で決定的に散らす
    /// (`String.hashValue` はプロセスごとに乱数化され再現しない = 同じ入力でも run ごとに port が変わる)
    static func stablePort(seed: String) -> Int {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let value = digest.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return 10000 + (value % 20000)
    }

    /// **DOM の入力欄 → 落とす a11y 要素の ref**(純粋)。**注入のときだけ差し替える**ための対応表。
    ///
    /// **ブリッジは自分の snapshot の ref しか受け付けない**(`BridgeRouter.centerOf` は未知の ref を
    /// 404)。DOM ノードにはホスト側で新しい ref を振るので、そのまま渡すと
    /// **`type` / `clearInput` だけが 404 で落ちる**(タップは座標をホストが持っているので通る)。
    /// 差し替えれば注入は従来どおりブリッジの経路(SET_TEXT + resource-id 追跡 + 読み返し。
    /// docs/design.md §Android のテキスト注入の規律)にそのまま乗る。
    ///
    /// **木の ref そのものは書き換えない** —— `z` を持たない要素の塗り順は ref 順に落ちるので、
    /// 入力欄だけ小さい ref にすると**その欄が兄弟の裏にあると判定される**。
    ///
    /// **対応付けるのは入力欄だけ**(他の型は座標で操作するので ref を要らない)。
    /// 規則は**中心点を含む最小の a11y 入力欄**。同じ大きさで並ぶ等で決まらないときは
    /// **対応付けない** —— 取り違えると**画面に出ているのと違う欄へ書き込む**(沈黙する誤り)。
    /// 404 なら少なくとも気付ける
    static func bridgeRefMap(dom: [ElementInfo], droppedA11y: [ElementInfo]) -> [Int: Int] {
        let inputs: Set<String> = ["textField", "secureTextField", "textView", "searchField"]
        let a11yInputs = droppedA11y.filter { inputs.contains($0.type) }
        guard !a11yInputs.isEmpty else { return [:] }
        func area(_ element: ElementInfo) -> Double { element.frame.width * element.frame.height }
        var map: [Int: Int] = [:]
        var taken: Set<Int> = []
        for node in dom where inputs.contains(node.type) {
            let x = node.frame.centerX, y = node.frame.centerY
            let ranked = a11yInputs.filter {
                !taken.contains($0.ref)
                    && $0.frame.x <= x && x <= $0.frame.x + $0.frame.width
                    && $0.frame.y <= y && y <= $0.frame.y + $0.frame.height
            }.sorted { area($0) < area($1) }
            guard let best = ranked.first else { continue }
            // 最小が1つに決まらない(同面積が並ぶ)なら当てずっぽうにしない
            if ranked.count > 1, !(area(best) < area(ranked[1])) { continue }
            taken.insert(best.ref)
            map[node.ref] = best.ref
        }
        return map
    }

    /// forward の host port の種(純粋)。**ブラウザは serial だけ**(既存の値を動かさない)。
    /// 自作アプリはソケット名を混ぜる —— 同じ端末のブラウザ経路と自作アプリ経路が
    /// 別プロセスから同時に forward されうるので、同じ port を取り合わせない
    static func portSeed(serial: String, appSocket: String?) -> String {
        guard let appSocket else { return serial }
        return "\(serial)#\(appSocket)"
    }
}

// MARK: - I/O(adb + CDP)。ここはデバイスが要るので純粋部分と分けてある

public extension AndroidWebViewDOM {

    /// **既定はオン**。ブラウザ本体の殺しスイッチ `FT_BROWSER_DOM=off`(iOS Safari 側と同じ変数)
    static var isBrowserDOMEnabled: Bool {
        (ProcessInfo.processInfo.environment["FT_BROWSER_DOM"] ?? "").lowercased() != "off"
    }

    /// **既定はオン**。自作アプリの WebView の殺しスイッチ `FT_WEBVIEW_DOM=off`。
    /// **iOS in-app 側と同じ変数・同じ意味**(= テスト対象アプリの WebView を DOM で読むか)で、
    /// ブラウザの `FT_BROWSER_DOM` とは口を分ける(冒頭参照)
    static var isAppWebViewDOMEnabled: Bool {
        (ProcessInfo.processInfo.environment["FT_WEBVIEW_DOM"] ?? "").lowercased() != "off"
    }

    /// CDP で能動タブ/ページの DOM を1往復読む。**失敗は握って nil**(未対応ブラウザ・非公開ソケット・
    /// WebView 未生成・タブ未選択はどれも普通にあるので、取れないことを例外にしない。呼び出し側は
    /// この nil を「従来どおり a11y のまま」に読み替える)。
    /// **経路の判定はここでしない**(`route` で済ませて渡す)

    /// ソケット解決 → port forward → タブ一覧 → 順位付け までを1箇所に置き、
    /// **繋いだ状態のまま** body へ候補の WebSocket URL を渡す(forward は body の間だけ張る)。
    /// DOM 読みとページ画像の取得が同じ経路を通るための土台
    private static func withRankedTabs<T>(
        serial: String, packageID: String, route: Route,
        webViewLabel: String?, urlBarValue: String?,
        adb: (_ args: [String]) throws -> String,
        _ body: ([String]) async -> T?) async -> T? {
        let socket: String
        // ブラウザは serial だけで port を決める(既存の値を動かさない。portSeed の宣言参照)
        let appSocket: String?
        switch route {
        case .a11y:
            return nil
        case .browser(let name):
            socket = name
            appSocket = nil
        case .appWebView:
            guard let command = probeCommand(packageID: packageID),
                  let output = try? adb(command),
                  case .socket(let name) = resolveAppSocket(probeOutput: output) else { return nil }
            socket = name
            appSocket = name
        }
        let port = stablePort(seed: portSeed(serial: serial, appSocket: appSocket))
        guard (try? adb(["forward", "tcp:\(port)", "localabstract:\(socket)"])) != nil else { return nil }
        defer { _ = try? adb(["forward", "--remove", "tcp:\(port)"]) }
        guard let list = await getJSON(port: port) else { return nil }
        let ranked = rankedTabs(webViewLabel: webViewLabel, urlBarValue: urlBarValue, targets: list)
        return await body(Array(ranked.prefix(maxTabAttempts)))
    }

    /// **ページの画像を CDP から撮る**(`Page.captureScreenshot`)。
    /// Android の端末側キャプチャ(`UiAutomation.takeScreenshot` / `adb screencap` /
    /// エミュレータ gRPC のいずれも)は **WebView のレイヤを取り逃すことがある**
    /// (2026-08-20 に E2E-Android の WebView 画面で再現。木には全要素が居るのに
    /// 3経路とも同じ空白を返し、CDP だけが中身を返した)。失敗は握って nil
    static func capturePagePNG(serial: String, packageID: String, route: Route,
                               webViewLabel: String?, urlBarValue: String?,
                               adb: (_ args: [String]) throws -> String) async -> Data? {
        await withRankedTabs(serial: serial, packageID: packageID, route: route,
                             webViewLabel: webViewLabel, urlBarValue: urlBarValue, adb: adb) { tabs in
            for webSocket in tabs {
                guard let result = await call(webSocket: webSocket, method: "Page.captureScreenshot",
                                              params: ["format": "png"]),
                      let base64 = result["data"] as? String,
                      let png = Data(base64Encoded: base64), !png.isEmpty else { continue }
                return png
            }
            return nil
        }
    }

    static func read(serial: String, packageID: String, route: Route,
                     webViewLabel: String?, urlBarValue: String?,
                     adb: (_ args: [String]) throws -> String) async -> WebViewDOM.Payload? {
        await withRankedTabs(serial: serial, packageID: packageID, route: route,
                             webViewLabel: webViewLabel, urlBarValue: urlBarValue,
                             adb: adb) { tabs in
            await readFromTabs(tabs, route: route)
        }
    }

    private static func readFromTabs(_ tabs: [String], route: Route) async -> WebViewDOM.Payload? {
        // **応答したタブを能動タブとみなす**(順序の推測では決めない。rankedTabs の宣言参照)。
        // 背面タブは JS が止まっていて返らないので、締切で切って次の候補へ移る。
        // **試す数を絞る**: 上限が無いと、タブを大量に開いた端末で snapshot が候補数×締切だけ延びる
        // **生死を先に安く見る**(凍ったタブは待っても答えない。livenessTimeout の宣言参照)。
        // 当たったタブにだけ本命の JS を撃つ
        for webSocket in tabs {
            // **生死の事前確認はブラウザだけ**(2026-08-15)。これは凍った背面タブを安く見切る
            // ための仕掛けで、`livenessTimeout` は「答えないタブ」を諦める締切として 0.4s に
            // 詰めてある。**アプリ内 WebView はページが1枚しかなく飛ばす相手が居ない**うえ、
            // 初回 attach はこの締切に収まらないので、掛けると**生きているのに落とす**
            // (実測: E2E の 36/36 が liveness で false → 木が丸ごと a11y へ落ちていた)
            if case .browser = route {
                guard await evaluate(webSocket: webSocket, javaScript: "1+1",
                                     timeout: livenessTimeout) != nil else { continue }
            }
            guard let json = await evaluate(webSocket: webSocket, javaScript: WebViewDOM.javaScript),
                  let payload = try? WebViewDOM.decode(json), payload.error == nil else { continue }
            return payload
        }
        return nil
    }

    private static func getJSON(port: Int) async -> [[String: Any]]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// DOM 評価の締切(秒)。実測は前面タブで 33ms。**選んだタブが当たった後**の待ちなので広めでよい
    static let evaluateTimeout: Double = 3

    /// **生きているタブかを見る安い問い合わせの締切(秒)**。
    /// **凍ったタブは待っても絶対に答えない**(実測: 19 タブ中 18 が 3005ms で無応答、
    /// 生きている1つは 11ms)。ここを評価と同じ 3 秒にしていたため、外すたびに 3 秒を捨てて
    /// **snapshot の中央値が 9.5 秒**になっていた(DOM オフは 126ms)。
    /// 生死の判定に大きな JS は要らないので `1+1` を撃つ
    static let livenessTimeout: Double = 0.4

    /// 試すタブ数の上限。**外した候補1つにつき締切ぶん待つ**ので、上限が無いと
    /// タブを大量に開いた端末で snapshot が候補数 × 3秒だけ延びる
    static let maxTabAttempts = 3

    /// `Runtime.evaluate` を1回だけ撃つ(戻り値は評価結果の文字列)
    private static func evaluate(webSocket: String, javaScript: String,
                                 timeout: Double = evaluateTimeout) async -> String? {
        let result = await call(webSocket: webSocket, method: "Runtime.evaluate",
                                params: ["expression": javaScript, "returnByValue": true,
                                         "awaitPromise": false],
                                timeout: timeout)
        return ((result?["result"] as? [String: Any])?["value"]) as? String
    }

    /// CDP を1往復。**WebSocket は Foundation 標準**を使う
    /// (依存を足さない。CDP に要るのは送信1件・受信1件だけ)。戻り値は `result` の中身
    private static func call(webSocket: String, method: String, params: [String: Any],
                             timeout: Double = evaluateTimeout) async -> [String: Any]? {
        guard let url = URL(string: webSocket) else { return nil }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        // **必ず締切を付ける**(2026-08-13 の実害)。`URLSessionWebSocketTask.receive()` には
        // タイムアウトが無く、**Chrome は背面タブの JS を止める**ので評価の応答が永久に来ないことがある。
        // snapshot は最頻の操作なので、ここで止まると run ごと固まる(実測で 183 秒待っても返らなかった)。
        // ソケットを閉じると受信側が throw で起きるため、番犬は cancel するだけでよい
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        let request: [String: Any] = ["id": 1, "method": method, "params": params]
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: body, encoding: .utf8),
              (try? await task.send(.string(text))) != nil else { return nil }
        // **id で照合する**: CDP はイベントも流すので、最初の1件が応答とは限らない
        for _ in 0..<20 {
            guard let message = try? await task.receive() else { return nil }
            guard case .string(let reply) = message,
                  let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8)))
                      as? [String: Any] else { continue }
            guard (object["id"] as? Int) == 1 else { continue }
            return object["result"] as? [String: Any]
        }
        return nil
    }
}
