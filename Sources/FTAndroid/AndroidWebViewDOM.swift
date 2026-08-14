// Android の**ブラウザ本体**のページ内容を DOM(CDP)から読む(2026-08-13)。
//
// **対象はブラウザだけ。自作アプリの WebView は a11y のまま読む**
// (ブラウザは本当にページを部分的にしか a11y へ出さない。経緯と根拠は docs/design.md
// §ブラウザの中身は DOM から読む)。
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
// **ソケット名はアプリ内 WebView と規則が違う**: `webview_devtools_remote_<pid>` は pid が
// 付くが、**Chrome のソケットは `@chrome_devtools_remote` で pid が付かない**(実測)。
// pid 一致規則では届かないので、ブラウザは**パッケージ名 → 固定ソケット名**の別規則を使う。
//
// **能動タブの選択が要る**: Chrome は複数タブを開くので `/json` は `type=page` を複数返す
// (実測で7件)。**順序では決まらない**(`/json` は MRU 順ではないと実測。詳細は `rankedTabs`)。
// 確からしい順に並べ、**上から評価を試して応答したものを能動タブとみなす** ——
// 背面タブは Chrome が JS を止めるので返らない。
//
// **木への差し込みは重複させない**: Chrome は簡単なページなら a11y へ本文を普通に公開する
// (example.com で `WebView` ノード + 本文の StaticText/Link が実際に出た)。素朴に DOM を
// append すると同じ本文が二重に並ぶ。**ブラウザでは DOM を web コンテンツ領域の唯一の正とする**
// —— `WebView` ノードの内側にある a11y 要素を落としてから DOM のノードを入れる
// (`droppingWebViewSubtree`)。ブラウザ chrome(`#url_bar` `#toolbar` 等 = WebView の外)は
// a11y のまま残す。条件付きで切り替えない(ページごとに a11y の充実度が変わるので、
// 「このページでは通るが別のページでは落ちる」を防ぐ)。
//
// **既定はオン**(対象をブラウザに絞ってあるので自作アプリへの影響が無い)。
// 殺しスイッチは `FT_BROWSER_DOM=off`(iOS in-app 側の `FT_WEBVIEW_DOM=off` と同じ語法)。
//
// **成立条件は未確認**。アプリ内 WebView は debuggable マニフェストが要ったが、Chrome の
// ソケット公開条件はまだ実測していない(実測できた端末では常に見えていた)。取れないときは
// 例外にせず黙って従来の a11y のまま(下の `read` の宣言参照)。

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

    /// 対象パッケージのブラウザ用ソケット名。既知集合に無ければ nil(= a11y のまま)
    public static func browserSocketName(packageID: String) -> String? {
        browserSockets[packageID]
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
}

// MARK: - I/O(adb + CDP)。ここはデバイスが要るので純粋部分と分けてある

public extension AndroidWebViewDOM {

    /// **既定はオン**(対象をブラウザに絞ってあるので自作アプリへは影響しない)。
    /// 殺しスイッチ `FT_BROWSER_DOM=off`(iOS in-app 側 `FT_WEBVIEW_DOM=off` と同じ語法)
    static var isBrowserDOMEnabled: Bool {
        (ProcessInfo.processInfo.environment["FT_BROWSER_DOM"] ?? "").lowercased() != "off"
    }

    /// CDP で能動タブの DOM を1往復読む。**失敗は握って nil**(未対応ブラウザ・非公開ソケット・
    /// タブ未選択はどれも普通にあるので、取れないことを例外にしない。呼び出し側はこの nil を
    /// 「従来どおり a11y のまま」に読み替える)
    static func read(serial: String, packageID: String, webViewLabel: String?, urlBarValue: String?,
                     adb: (_ args: [String]) throws -> String) async -> WebViewDOM.Payload? {
        guard let socket = browserSocketName(packageID: packageID) else { return nil }
        let port = stablePort(seed: serial)
        guard (try? adb(["forward", "tcp:\(port)", "localabstract:\(socket)"])) != nil else { return nil }
        defer { _ = try? adb(["forward", "--remove", "tcp:\(port)"]) }
        guard let list = await getJSON(port: port) else { return nil }
        // **応答したタブを能動タブとみなす**(順序の推測では決めない。rankedTabs の宣言参照)。
        // 背面タブは JS が止まっていて返らないので、締切で切って次の候補へ移る。
        // **試す数を絞る**: 上限が無いと、タブを大量に開いた端末で snapshot が候補数×締切だけ延びる
        // **生死を先に安く見る**(凍ったタブは待っても答えない。livenessTimeout の宣言参照)。
        // 当たったタブにだけ本命の JS を撃つ
        for socket in rankedTabs(webViewLabel: webViewLabel, urlBarValue: urlBarValue,
                                 targets: list).prefix(maxTabAttempts) {
            guard await evaluate(webSocket: socket, javaScript: "1+1",
                                 timeout: livenessTimeout) != nil else { continue }
            guard let json = await evaluate(webSocket: socket, javaScript: WebViewDOM.javaScript),
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

    /// `Runtime.evaluate` を1回だけ撃つ。**WebSocket は Foundation 標準**を使う
    /// (依存を足さない。CDP に要るのは送信1件・受信1件だけ)
    private static func evaluate(webSocket: String, javaScript: String,
                                 timeout: Double = evaluateTimeout) async -> String? {
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
        let request: [String: Any] = [
            "id": 1, "method": "Runtime.evaluate",
            "params": ["expression": javaScript, "returnByValue": true, "awaitPromise": false],
        ]
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
            let result = (object["result"] as? [String: Any])?["result"] as? [String: Any]
            return result?["value"] as? String
        }
        return nil
    }
}
