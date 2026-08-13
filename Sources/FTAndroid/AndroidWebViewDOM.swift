// Android の WebView の中身を **DOM から** 読む(2026-08-13)。
//
// **なぜ要るか**: `android.webkit.WebView` は `<table>` のセルを a11y ツリーへ**1つも公開しない**
// (2026-08-13 に 4 SUT で実測。Compose interop / Flutter / RN / 素の View のどれでも同じなので
// ホスト側の作りではなく WebView の性質)。同じページを iOS の WKWebView は公開するため、
// **同じ HTML なのに OS でセレクタが書き分けになる**。
//
// **JS は iOS と共有する**(`FTCore.WebViewDOM.javaScript`)。あちらは in-app エンジンから
// WKWebView の a11y が見えない事情で先に入った経路で、返す形(role/label/矩形)も共通なので、
// **同じ JS を Android で走らせれば木が一致する** = セレクタが同じ書き方で通る。
//
// **経路は CDP**(Chrome DevTools Protocol)。Android のブリッジはアクセシビリティサービスで
// 別プロセスなので、他アプリの WebView に `evaluateJavascript` を撃てない。ホスト側から
// `adb forward localabstract:webview_devtools_remote_<pid>` で入る。
//
// **成立条件はアプリが debuggable であること**(実測: どの SUT も
// `setWebContentsDebuggingEnabled` を呼んでいないのにソケットが在った = WebView が
// debuggable アプリに対して自動で公開する)。**デバイスが実機かどうかは無関係**。
// リリースビルドの他社アプリでは使えないので、**使えないときは黙って従来どおり**に落ちる
// (取れないことは `webViewGapNote` が別途告げる)。
//
// **既定はオフ**。`FT_ANDROID_WEBVIEW_DOM=1` で有効(spike。実測が揃うまで既定にしない)。

import Foundation
import FTCore

public enum AndroidWebViewDOM {

    /// `/proc/net/unix` の1行から `webview_devtools_remote_<pid>` を拾う(純粋)。
    /// **pid で絞る**: 端末には他アプリの WebView ソケットも並ぶので、対象アプリの pid と
    /// 一致するものだけを使わないと**別アプリの DOM を読む**(今日の監査で何度も踏んだ型)
    public static func socketName(procNetUnix: String, pid: Int) -> String? {
        let wanted = "webview_devtools_remote_\(pid)"
        for line in procNetUnix.split(separator: "\n") {
            guard let at = line.range(of: "@") else { continue }
            let name = line[at.upperBound...].trimmingCharacters(in: .whitespaces)
            if name == wanted { return name }
        }
        return nil
    }

    /// CDP の `/json` から評価対象のページを選ぶ(純粋)。
    /// **about:blank も候補にする** —— `loadDataWithBaseURL` で読ませた画面は url が about:blank
    /// になる(実測)。除くのは devtools 自身と、ページ以外の型だけ
    public static func pickPage(_ targets: [[String: Any]]) -> String? {
        for t in targets {
            guard (t["type"] as? String) == "page",
                  let ws = t["webSocketDebuggerUrl"] as? String, !ws.isEmpty else { continue }
            if (t["url"] as? String)?.hasPrefix("devtools://") == true { continue }
            return ws
        }
        return nil
    }

    /// DOM のノードを**画面座標の要素**へ写す(純粋)。
    ///
    /// JS は CSS px・visual viewport 相対で返す。Android は
    /// **CSS px × density = 物理 px** で、そこへ WebView ノードの画面上の原点を足す。
    /// (iOS 側は `UIView.convert` が担っていた部分。Android は a11y の bounds が既に物理 px)
    public static func elements(payload: WebViewDOM.Payload, webViewFrame: FTRect,
                                density: Double, startingRef: Int) -> [ElementInfo] {
        guard let nodes = payload.nodes, let viewport = payload.viewport else { return [] }
        var out: [ElementInfo] = []
        var ref = startingRef
        for node in nodes {
            guard let type = WebViewDOM.typeName(role: node.role) else { continue }
            let local = WebViewDOM.localRect(node, viewport: viewport)
            let frame = FTRect(x: webViewFrame.x + local.x * density,
                               y: webViewFrame.y + local.y * density,
                               width: local.width * density,
                               height: local.height * density)
            // 高さ・幅が 0 の要素は a11y 側の規約に合わせて落とす(SnapshotBuilder と同じ扱い)
            guard frame.width >= 1, frame.height >= 1 else { continue }
            // **web: true を立てる**(iOS の in-app 経路と同じ印)。読み手が
            // 「#id が効かない画面」だと判断する材料で、ここを落とすと OS で扱いが割れる
            out.append(ElementInfo(ref: ref, type: type, identifier: nil,
                                   label: node.label, value: node.value,
                                   placeholder: node.placeholder,
                                   enabled: node.enabled ?? true, frame: frame, depth: 1,
                                   checked: node.checked, web: true))
            ref += 1
        }
        return out
    }

    /// 木の中の WebView ノード(DOM を差し込む先)。**最大のものを選ぶ**
    /// —— 入れ子の WebView はブリッジ側で既に落としているが、複数並ぶ画面では
    /// 面積の大きいほうが本体である公算が高い
    public static func webViewFrame(in elements: [ElementInfo]) -> FTRect? {
        elements.filter { $0.type.lowercased() == "webview" }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?
            .frame
    }
}

// MARK: - I/O(adb + CDP)。ここはデバイスが要るので純粋部分と分けてある

public extension AndroidWebViewDOM {

    /// この spike が有効か。**既定はオフ**(実測が揃うまで既定の経路を変えない)
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FT_ANDROID_WEBVIEW_DOM"] == "1"
    }

    /// CDP で DOM を1往復読む。**失敗は握って nil**(使えない相手 = リリースビルドの他社アプリが
    /// 普通にあるので、取れないことを例外にしない。取れないことは webViewGapNote が別途告げる)
    static func read(serial: String, pid: Int, adb: (_ args: [String]) throws -> String)
        async -> WebViewDOM.Payload? {
        guard let proc = try? adb(["shell", "cat", "/proc/net/unix"]),
              let socket = socketName(procNetUnix: proc, pid: pid) else { return nil }
        // **ポートは serial ごとに固定**(並列 run で衝突しないよう pid から決める)。
        // 既に張ってあれば adb 側が同じものを返すだけなので毎回張ってよい
        let port = 10000 + (pid % 20000)
        guard (try? adb(["forward", "tcp:\(port)", "localabstract:\(socket)"])) != nil else { return nil }
        defer { _ = try? adb(["forward", "--remove", "tcp:\(port)"]) }
        guard let list = await getJSON(port: port), let ws = pickPage(list) else { return nil }
        guard let json = await evaluate(webSocket: ws, javaScript: WebViewDOM.javaScript) else { return nil }
        guard let payload = try? WebViewDOM.decode(json), payload.error == nil else { return nil }
        return payload
    }

    private static func getJSON(port: Int) async -> [[String: Any]]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// `Runtime.evaluate` を1回だけ撃つ。**WebSocket は Foundation 標準**を使う
    /// (依存を足さない。CDP に要るのは送信1件・受信1件だけ)
    private static func evaluate(webSocket: String, javaScript: String) async -> String? {
        guard let url = URL(string: webSocket) else { return nil }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
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
