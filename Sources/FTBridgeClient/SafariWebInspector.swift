// シミュレータ/実機の Safari を WebKit remote inspector 越しに DOM から読む。
//
// **対象は Safari(`com.apple.mobilesafari`)だけ**。シミュレータは `/private/var/tmp` 等の
// unix ソケットに直結する。実機は usbmuxd(`/var/run/usbmuxd`)→ lockdownd → TLS →
// webinspectord という別の口を通る(`PhysicalSafariInspector.swift`)。**この先の
// フレーミング・plist メッセージ・Target 包みは完全に共通**(`InspectorTransport` 越しに
// 同じ `evaluate` を通す) —— 違うのはソケットの開け方だけ。
//
// **プロトコルは CDP ではない**(Android/Chrome と違う)。フレームは
// **4byte ビッグエンディアン長 + バイナリ plist**(`{"__selector": <name>, "__argument": <dict>}`)。
// CDP 本体(JSON)はその plist の `WIRSocketDataKey`/`WIRMessageDataKey` に載って往復する。
// **現代の WebKit は `Runtime` ドメインを素で受け付けない**(`'Runtime' domain was not found`)。
// `Target.targetCreated` イベントを待って targetId を採り、`Target.sendMessageToTarget` で
// 内側の CDP リクエストを JSON 文字列にして包む必要がある。応答は
// `Target.dispatchMessageFromTarget` の `params.message`(文字列)に入って返る。
//
// **JS は iOS in-app 経路(`WebViewDOM.javaScript`)と共有する** —— 返す形(role/label/矩形)が
// 揃うので、アプリ内 WebView とブラウザ本体で同じ書き方のセレクタが通る。
//
// **既定オン・殺しスイッチ `FT_BROWSER_DOM=off`**。取れなければ黙って a11y のまま
// (Safari 未起動・タブ無し・ソケット未検出・タイムアウトはどれも珍しくない失敗)。

import Foundation
import Darwin
import FTCore

public enum SafariWebInspector {

    public static let safariBundleID = "com.apple.mobilesafari"

    // MARK: - フレーミング(純粋: 長さ前置 4byte BE + 本体)

    public static func encodeFrame(_ body: Data) -> Data {
        var out = writeUInt32BE(UInt32(body.count))
        out.append(body)
        return out
    }

    /// バッファ先頭から1フレーム切り出す。**4byte 境界に満たなければ nil**
    /// (呼び出し側は読み増してから再試行する。1回の recv でフレーム全体が揃う保証は無い)
    public static func extractFrame(from buffer: Data) -> (body: Data, rest: Data)? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = Int(readUInt32BE(buffer.subdata(in: start..<(start + 4))))
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: (start + 4)..<(start + 4 + length))
        let rest = buffer.subdata(in: (start + 4 + length)..<buffer.endIndex)
        return (body, rest)
    }

    /// unaligned load を避けるため手でビッグエンディアンを組み立てる(`Data.withUnsafeBytes` の
    /// アライメント前提に依存しない)
    static func readUInt32BE(_ bytes: Data) -> UInt32 {
        let b = Array(bytes)
        guard b.count >= 4 else { return 0 }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    static func writeUInt32BE(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    // MARK: - plist メッセージ(selector/argument の組み立て・分解)

    enum PlistMessageError: Error { case malformed }

    static func encodePlistMessage(selector: String, argument: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["__selector": selector, "__argument": argument],
                                           format: .binary, options: 0)
    }

    static func decodePlistMessage(_ data: Data) throws -> (selector: String, argument: [String: Any]) {
        guard let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [String: Any], let selector = dict["__selector"] as? String else {
            throw PlistMessageError.malformed
        }
        return (selector, dict["__argument"] as? [String: Any] ?? [:])
    }

    // MARK: - アプリ選択(純粋)

    /// `_rpc_reportConnectedApplicationList:`/`_rpc_applicationConnected:` から積んだ
    /// applicationId→辞書 の中から Safari を選ぶ。**bundle id で判定する**(実測のキーは
    /// `WIRApplicationBundleIdentifierKey`)。名前(`WIRApplicationNameKey`)の部分一致は
    /// `com.apple.WebKit.WebContent` 等の別プロセスを誤って拾い得るため使わない
    public static func pickSafariApplicationId(_ apps: [String: [String: Any]]) -> String? {
        apps.first { _, info in (info["WIRApplicationBundleIdentifierKey"] as? String) == safariBundleID }?.key
    }

    // MARK: - ページ選択(純粋)

    /// `_rpc_applicationSentListing:` の `WIRListingKey`(ページid文字列→辞書)から評価対象を選ぶ。
    /// **`WIRTypeKey == "WIRTypeWebPage"` だけを候補にし、id が最大のものを選ぶ** ——
    /// ページ辞書に「今どれが前面か」を示すフラグが無く、実測(2026-08-13・2タブ)では
    /// 後から開いたタブほど id が大きく、フォアグラウンドのタブと一致した。これが唯一の手掛かり
    public static func pickPageId(_ listing: [String: [String: Any]]) -> Int? {
        listing.compactMap { key, info -> Int? in
            guard (info["WIRTypeKey"] as? String) == "WIRTypeWebPage" else { return nil }
            return (info["WIRPageIdentifierKey"] as? Int) ?? Int(key)
        }.max()
    }

    // MARK: - Target 包み/剥がし(純粋)

    /// `Target.targetCreated` イベントから targetId を取り出す。来るまで待つ必要がある
    /// (これより前に `Runtime.evaluate` を素で送ると 'Runtime' domain was not found で落ちる)
    public static func targetCreatedId(_ message: [String: Any]) -> String? {
        guard (message["method"] as? String) == "Target.targetCreated",
              let params = message["params"] as? [String: Any],
              let info = params["targetInfo"] as? [String: Any] else { return nil }
        return info["targetId"] as? String
    }

    enum WrapError: Error { case encodingFailed }

    /// 内側の CDP リクエストを `Target.sendMessageToTarget` で包む。**内側は JSON 文字列にして積む**
    /// (WebKit 側がその形でしか受けない。素の辞書のままだと届かない)
    public static func wrapInTarget(targetId: String, envelopeId: Int, inner: [String: Any]) throws -> [String: Any] {
        let innerData = try JSONSerialization.data(withJSONObject: inner)
        guard let innerText = String(data: innerData, encoding: .utf8) else { throw WrapError.encodingFailed }
        return ["id": envelopeId, "method": "Target.sendMessageToTarget",
                "params": ["targetId": targetId, "message": innerText]]
    }

    /// `Target.dispatchMessageFromTarget` に包まれた応答を剥がす。
    /// 包まれていないメッセージ(将来 Target を介さない応答が来た場合の保険)はそのまま返す
    public static func unwrapTargetMessage(_ message: [String: Any]) -> [String: Any]? {
        guard (message["method"] as? String) == "Target.dispatchMessageFromTarget",
              let params = message["params"] as? [String: Any] else { return message }
        if let text = params["message"] as? String, let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        return params["message"] as? [String: Any]
    }

    // MARK: - 気付けるようにする(**この2つは人の操作でしか直せない**)

    /// ブラウザ DOM が取れなかったときに、**人が直せる原因なら名指しする**(純粋)。
    /// 黙って a11y へ落ちるだけだと「このツールは Safari を読めない」と誤解される。
    ///
    /// - `handshakeRefused`: `_rpc_reportIdentifier:` すら送れずに切られた。実機で
    ///   **Web インスペクタが無効**のときの実測どおりの形(TLS までは通り、直後に切断)
    /// - `apps` に Safari が居ない: **有効化より前から動いていた Safari は webinspectord に
    ///   登録されない**(実測。デーモンだけが並ぶ)。起動し直せば載る
    static func inspectorHint(handshakeRefused: Bool, apps: [String: [String: Any]]) -> String? {
        if handshakeRefused {
            return "fleetest: the Safari web inspector refused the connection."
                + " On a physical device, enable Settings > Safari > Advanced > Web Inspector."
                + " (falling back to the accessibility tree)"
        }
        guard !apps.isEmpty, pickSafariApplicationId(apps) == nil else { return nil }
        return "fleetest: Safari is not registered with the web inspector."
            + " Relaunch Safari — enabling Web Inspector does not apply to an app that was"
            + " already running. (falling back to the accessibility tree)"
    }

    static func reportInspectorHint(handshakeRefused: Bool, apps: [String: [String: Any]]) {
        guard let hint = inspectorHint(handshakeRefused: handshakeRefused, apps: apps) else { return }
        FileHandle.standardError.write(Data((hint + "\n").utf8))
    }

    /// JS の文字列を JS のリテラルへ(引用符・バックスラッシュ・改行のエスケープを自分で書かない)
    static func jsStringLiteral(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8), json.count >= 2 else { return nil }
        return String(json.dropFirst().dropLast())
    }

    /// **1通が予算に収まるようにソースを分割し、グローバルへ積む式の列**を作る(純粋)。
    ///
    /// 実機では 1通のフレームが大きいと黙って捨てられるので、共有 JS(約 9.7KB)は1通で送れない。
    /// **共有 JS 自体は1文字も変えない** —— 変えるとシミュレータ・Android・in-app と別物になる。
    ///
    /// **切るのはソースの長さではなくフレーム長**(サイズ計算は `frameSize` で外から渡す)。
    /// JSON のリテラル化で **1.2 倍**に膨らみ、しかも膨張率は場所によって違うため
    /// (実測: ソース 3000 → フレーム 5546 / 4000 → 8630)、ソース長で切ると予算を超える。
    ///
    /// **文字単位で切る**: JS には日本語コメントが入っているので、バイトで切ると
    /// UTF-8 の途中で割れて壊れる
    static func assemblyExpressions(javaScript: String, budget: Int,
                                    frameSize: (String) -> Int) -> [String]? {
        let characters = Array(javaScript)
        var expressions: [String] = []
        var index = 0
        while index < characters.count {
            let assign = expressions.isEmpty ? "=" : "+="
            // 予算に収まる最大の文字数を二分探索する(1文字でも入らないなら組み立て不能)
            var low = 0, high = characters.count - index
            while low < high {
                let middle = (low + high + 1) / 2
                guard let literal = jsStringLiteral(String(characters[index..<(index + middle)])) else { return nil }
                if frameSize("globalThis.__ftSrc\(assign)\(literal);\"ok\"") <= budget { low = middle } else { high = middle - 1 }
            }
            guard low > 0,
                  let literal = jsStringLiteral(String(characters[index..<(index + low)])) else { return nil }
            expressions.append("globalThis.__ftSrc\(assign)\(literal);\"ok\"")
            index += low
        }
        return expressions.isEmpty ? nil : expressions
    }

    /// 積み終えたソースを実行して**後片付けまでする**式。ページに `__ftSrc` を残さない
    /// (残すと次の読みで前回の残骸に足してしまう)。共有 JS は IIFE なので eval の戻り値が結果
    static let assemblyRunExpression =
        "(function(){var s=globalThis.__ftSrc;delete globalThis.__ftSrc;return (0,eval)(s);})()"

    /// `Runtime.evaluate` の応答から評価結果の文字列値を取り出す。**id が一致するときだけ**
    /// (CDP は要求と無関係なイベントも流すため、id 照合を飛ばすと別の応答を掴む)
    public static func extractEvaluateResult(_ message: [String: Any], expectingId: Int) -> String? {
        guard (message["id"] as? Int) == expectingId else { return nil }
        let result = message["result"] as? [String: Any]
        return (result?["result"] as? [String: Any])?["value"] as? String
    }

    // MARK: - ソケット選択(純粋パース。I/O は下の extension)

    /// `lsof -Fpn <sockets…>` の出力から「ソケットパス→pid」を作る。
    /// **-F(machine readable)形式**: `p<pid>` 行の後に `f<fd>`/`n<path>` の対が並ぶ。
    /// 同じ pid が同じソケットを複数 fd で開くことがある(実測)ので後勝ちで上書きしてよい
    public static func parseLsofPidsByPath(_ output: String) -> [String: Int] {
        var result: [String: Int] = [:]
        var currentPid: Int?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch tag {
            case "p": currentPid = Int(value)
            case "n": if let pid = currentPid { result[value] = pid }
            default: break
            }
        }
        return result
    }

    /// `ps -o pid=,command= -p <pids…>` の出力から「pid→コマンドライン」を作る
    public static func parsePsCommandsByPid(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(of: " "), let pid = Int(trimmed[..<spaceIndex]) else { continue }
            result[pid] = String(trimmed[trimmed.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// `launchd_sim` のコマンドラインから UDID を取り出す。パスは
    /// `.../CoreSimulator/Devices/<UDID>/data/var/run/launchd_bootstrap.plist`(実測で固定・2026-08-13)。
    /// これが**ソケットのディレクトリ名(`com.apple.launchd.XXXX`)と UDID を結ぶ唯一の経路**
    /// (webinspectord のソケット自体に UDID は載らない。全ソケットに接続して探る案より
    /// 2桁安い: `lsof` 1回 + `ps` 1回で全台ぶん解決できる。実測: 10台で計 1秒未満)
    public static func udid(fromLaunchdSimCommandLine commandLine: String) -> String? {
        guard let range = commandLine.range(of: "CoreSimulator/Devices/") else { return nil }
        let after = commandLine[range.upperBound...]
        guard let slash = after.firstIndex(of: "/") else { return nil }
        let candidate = String(after[after.startIndex..<slash])
        // UDID は 8-4-4-4-12 桁の16進(simctl の出力形式)。桁が違えば別物として弾く
        guard candidate.split(separator: "-").map(\.count) == [8, 4, 4, 4, 12] else { return nil }
        return candidate
    }

    /// 対象 UDID のソケットパスを選ぶ(純粋。lsof/ps の生出力をここで受け取る)
    public static func socketPath(forUDID udid: String, sockets: [String],
                                  lsofOutput: String, psOutput: String) -> String? {
        let pidsByPath = parseLsofPidsByPath(lsofOutput)
        let commandsByPid = parsePsCommandsByPid(psOutput)
        for socket in sockets {
            guard let pid = pidsByPath[socket], let command = commandsByPid[pid] else { continue }
            if Self.udid(fromLaunchdSimCommandLine: command) == udid { return socket }
        }
        return nil
    }

    // MARK: - 木への差し込み

    /// 座標写し・WebView 選択・差し込みは `FTCore.WebViewDOM` を直接呼ぶ(Android と同じ関数。
    /// ここに2つ目の実装を持たない)。**iOS は `density: 1` で呼ぶ** —— a11y frame が既に pt
    /// なので Android(物理 px なので density を掛ける)と違って倍率は要らない。
    /// 呼び出しは `BridgeClient.snapshot(query:)`(木の組み立て箇所)。

    /// 殺しスイッチの判定(純粋)。**`"off"` のときだけ無効**(既定オン)
    /// **大小文字を無視する**(2026-08-13 のレビュー指摘)。Android(`AndroidWebViewDOM`)と
    /// in-app(`InAppWebViewDOM`)は `.lowercased()` で見ているので、ここだけ素の比較だと
    /// `FT_BROWSER_DOM=OFF` で**片肺**になる(片方だけ止まると A/B の陽性対照が壊れる)
    public static func isEnabled(env: [String: String]) -> Bool {
        (env["FT_BROWSER_DOM"] ?? "").lowercased() != "off"
    }
}

// MARK: - I/O(unix domain socket + plist フレーミング + ソケット解決)。デバイスが要るので分けてある

public extension SafariWebInspector {

    static var isEnabled: Bool {
        isEnabled(env: ProcessInfo.processInfo.environment)
    }

    /// UDID のシミュレータの Safari から DOM を1往復読む。**失敗は握って nil**
    /// (Safari 未起動・タブ無し・ソケット未検出・タイムアウトはどれも珍しくない。
    /// 取れないときは呼び出し側が黙って a11y のまま続ける前提)
    static func read(udid: String) async -> WebViewDOM.Payload? {
        guard isEnabled else { return nil }
        guard let socketPath = resolveSocketPath(forUDID: udid) else { return nil }
        guard let connection = SafariInspectorConnection(path: socketPath) else { return nil }
        defer { connection.close() }
        guard let json = evaluate(over: connection, overallDeadline: Date().addingTimeInterval(readBudget))
        else { return nil }
        guard let payload = try? WebViewDOM.decode(json), payload.error == nil else { return nil }
        return payload
    }

    /// ハードウェア UDID の実機の Safari から DOM を1往復読む。**握り経路は
    /// usbmuxd → lockdownd → TLS → webinspectord**(`PhysicalSafariInspector.connect`)。
    /// 未ペアリング・USB 未接続・Web インスペクタ無効はどれも珍しくないので**失敗は握って nil**
    /// (`PhysicalSafariInspector` 内で `InvalidService` だけ例外的に stderr へ知らせる)
    static func read(physicalUDID: String) async -> WebViewDOM.Payload? {
        guard isEnabled else { return nil }
        // **実機は1通あたりのフレーム長に上限がある**(分割する理由は messageBudgets の宣言)。
        // **退避のたびに繋ぎ直す** —— 同じ接続で RPC をやり直すと、2周目は
        // `_rpc_getConnectedApplications:` にアプリ一覧が返らず必ず失敗する(2026-08-13 に実機で実測)。
        // **退避も含めて全体の締切の内側**(段ごとの締切を足すだけだと分単位で沈黙し得る。
        // snapshot は最頻の操作)
        let overall = Date().addingTimeInterval(readBudget)
        for (attempt, budget) in Self.messageBudgets.enumerated() {
            guard Date() < overall else { break }
            // **閉じた直後に繋ぎ直すと2周目のアプリ一覧が返らない**(実測)。間を置く
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(reconnectPause * 1_000_000_000)) }
            // ハンドシェイク(usbmuxd 3往復 + lockdown 2往復 + TLS 2回)の予算
            guard let connection = PhysicalSafariInspector.connect(
                hardwareUDID: physicalUDID,
                deadline: min(Date().addingTimeInterval(10), overall)) else { return nil }
            let json = evaluate(over: connection, messageBudget: budget, overallDeadline: overall)
            connection.close()
            guard let json, let payload = try? WebViewDOM.decode(json), payload.error == nil
            else { continue }
            return payload
        }
        return nil
    }

    /// **DOM 読みが1回で使ってよい上限(秒)**。段ごとの締切の合計ではなく、
    /// ここが天井になる(退避のやり直しも内側)。実測は前面タブで 226ms なので十分に広く、
    /// **黙って分単位で止まらない**ことのほうが大事。Android 側の `evaluateTimeout` と同じ規律
    static let readBudget: TimeInterval = 30

    /// 退避で繋ぎ直す前に置く間(秒)。**0 にすると2周目のアプリ一覧が返らない**(実測)
    static let reconnectPause: TimeInterval = 1.5

    /// **実機だけ、1通が大きいと黙って捨てられる**(2026-08-13 実測)。エラーも応答も返らず、
    /// 60 秒待っても来ない。しかも**上限は固定ではない** —— 同じ端末・同じページで2回測って
    /// 境界がフレーム 7917/7981 と 8493/8557 に割れた(約 600 バイトの揺れ)。
    /// 測った境界のギリギリは狙わず、まず 7000 で試し、駄目なら 4000 へ落とす。
    /// **落ちたあとも接続は生きている**ので同じ接続で送り直せる(実測)。
    /// シミュレータに上限は無い(9.7KB を1通で 7ms)ので分割しない
    static let messageBudgets = [7000, 4000]

    /// `/private/var/tmp/com.apple.launchd.*/com.apple.webinspectord_sim.socket` を
    /// 対象 UDID まで絞り込む。**全ソケットへ接続して探る案は採らない**(2026-08-13 実測で
    /// 10台ぶん Safari を probe すると約1〜2秒×台数がかかる)。`lsof`+`ps` の2コマンドで
    /// 全ソケット→pid→UDID を1秒未満に解決できるため、こちらを既定にした
    private static func resolveSocketPath(forUDID udid: String) -> String? {
        let sockets = discoverSockets()
        guard !sockets.isEmpty else { return nil }
        guard let lsofResult = try? Shell.run(["lsof", "-Fpn"] + sockets, timeout: 5) else { return nil }
        let pids = Set(parseLsofPidsByPath(lsofResult.output).values).map(String.init)
        guard !pids.isEmpty,
              let psResult = try? Shell.run(["ps", "-o", "pid=,command=", "-p", pids.joined(separator: ",")],
                                            timeout: 5) else { return nil }
        return socketPath(forUDID: udid, sockets: sockets, lsofOutput: lsofResult.output, psOutput: psResult.output)
    }

    /// **根は2つある**(2026-08-13 に実測で踏んだ)。ソケットの置き場所は
    /// シミュレータを起こしたプロセスの `TMPDIR` で決まるので、`/private/var/tmp`(`/var/tmp`)と
    /// `/private/tmp`(`/tmp`)の**両方**を見ないと取りこぼす —— macOS ではこの2つは別ディレクトリで、
    /// 同じ機械の上で Xcode 由来のシミュレータは前者、シェルから `simctl boot` したものは後者に出た。
    /// 片方だけ見ていたときは、起動したての1台が丸ごと見えず `read` が黙って nil を返した
    static let socketRoots = ["/private/var/tmp", "/private/tmp"]

    private static func discoverSockets(fileManager: FileManager = .default) -> [String] {
        socketRoots.flatMap { root -> [String] in
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
            return entries.filter { $0.hasPrefix("com.apple.launchd.") }
                .map { "\(root)/\($0)/com.apple.webinspectord_sim.socket" }
                .filter { fileManager.fileExists(atPath: $0) }
        }
    }

    /// 一連の RPC(reportIdentifier → getConnectedApplications → forwardGetListing →
    /// forwardSocketSetup → Target 越しの Runtime.evaluate)を1本の接続で順に往復する。
    /// 各段に締切があり、**越えたら nil**(Safari が居ない・タブが無い等はここで自然に諦める)。
    /// **`InspectorTransport` 越し** —— シミュレータ(unix ソケット)と実機(usbmuxd 経由の
    /// TLS ソケット)でソケットの開け方は違うが、この先の RPC はどちらも同じ
    private static func evaluate(over connection: InspectorTransport,
                                 messageBudget: Int? = nil,
                                 overallDeadline: Date) -> String? {
        /// 段ごとの締切は**全体の締切で頭打ちにする**(段の合計が天井を超えないこと)
        func stageDeadline(_ seconds: TimeInterval) -> Date {
            min(Date().addingTimeInterval(seconds), overallDeadline)
        }
        let connectionId = UUID().uuidString.uppercased()
        let senderId = UUID().uuidString.uppercased()

        func send(_ selector: String, _ argument: [String: Any]) -> Bool {
            guard let body = try? encodePlistMessage(selector: selector, argument: argument) else { return false }
            return connection.send(encodeFrame(body))
        }

        func receive(deadline: Date) -> (selector: String, argument: [String: Any])? {
            guard let body = connection.receiveFrame(deadline: deadline) else { return nil }
            return try? decodePlistMessage(body)
        }

        // **送れずに切られたら Web インスペクタ無効の疑い**(実測の形。inspectorHint 参照)
        guard send("_rpc_reportIdentifier:", ["WIRConnectionIdentifierKey": connectionId]),
              send("_rpc_getConnectedApplications:", ["WIRConnectionIdentifierKey": connectionId]) else {
            reportInspectorHint(handshakeRefused: true, apps: [:])
            return nil
        }

        var apps: [String: [String: Any]] = [:]
        let appsDeadline = stageDeadline(4)
        while pickSafariApplicationId(apps) == nil, Date() < appsDeadline {
            guard let (selector, argument) = receive(deadline: appsDeadline) else { continue }
            switch selector {
            case "_rpc_reportConnectedApplicationList:":
                if let dict = argument["WIRApplicationDictionaryKey"] as? [String: [String: Any]] {
                    apps.merge(dict) { _, new in new }
                }
            case "_rpc_applicationConnected:":
                if let id = argument["WIRApplicationIdentifierKey"] as? String { apps[id] = argument }
            default: break
            }
        }
        guard let appId = pickSafariApplicationId(apps) else {
            // 他のアプリは見えているのに Safari だけ居ない = 起動し直しが要る(inspectorHint 参照)
            reportInspectorHint(handshakeRefused: false, apps: apps)
            return nil
        }

        guard send("_rpc_forwardGetListing:", ["WIRConnectionIdentifierKey": connectionId,
                                                "WIRApplicationIdentifierKey": appId]) else { return nil }
        var listing: [String: [String: Any]] = [:]
        let listingDeadline = stageDeadline(4)
        while listing.isEmpty, Date() < listingDeadline {
            guard let (selector, argument) = receive(deadline: listingDeadline),
                  selector == "_rpc_applicationSentListing:" else { continue }
            if let dict = argument["WIRListingKey"] as? [String: [String: Any]] { listing = dict }
        }
        guard let pageId = pickPageId(listing) else { return nil }

        let base: [String: Any] = ["WIRConnectionIdentifierKey": connectionId, "WIRApplicationIdentifierKey": appId,
                                   "WIRPageIdentifierKey": pageId, "WIRSenderKey": senderId]
        guard send("_rpc_forwardSocketSetup:", base) else { return nil }

        func sendCDP(_ object: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            var argument = base
            argument["WIRSocketDataKey"] = data
            return send("_rpc_forwardSocketData:", argument)
        }

        func pumpCDP(deadline: Date) -> [String: Any]? {
            guard let (selector, argument) = receive(deadline: deadline), selector == "_rpc_applicationSentData:",
                  let data = argument["WIRMessageDataKey"] as? Data,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return unwrapTargetMessage(object) ?? object
        }

        var targetId: String?
        let targetDeadline = stageDeadline(6)
        while targetId == nil, Date() < targetDeadline {
            guard let message = pumpCDP(deadline: targetDeadline) else { continue }
            targetId = targetCreatedId(message)
        }
        guard let targetId else { return nil }

        /// 1つの式を撃って結果の文字列を待つ。**大きすぎる1通は黙って捨てられる**ので、
        /// 返らなければ nil(呼び出し側が小さい予算で組み直す)
        func evaluateExpression(_ expression: String, id: Int, timeout: TimeInterval) -> String? {
            let inner: [String: Any] = ["id": id, "method": "Runtime.evaluate",
                                        "params": ["expression": expression, "returnByValue": true]]
            guard let envelope = try? wrapInTarget(targetId: targetId, envelopeId: 50 + id, inner: inner),
                  sendCDP(envelope) else { return nil }
            let deadline = stageDeadline(timeout)
            while Date() < deadline {
                guard let message = pumpCDP(deadline: deadline) else { continue }
                if let value = extractEvaluateResult(message, expectingId: id) { return value }
            }
            return nil
        }

        guard let budget = messageBudget else {
            // シミュレータは1通で送れる(上限が無い)
            return evaluateExpression(WebViewDOM.javaScript, id: 1, timeout: 15)
        }

        // フレーム長は実際に組み立てて測る(plist ヘッダ・Target 包み・JSON エスケープを込みで見る)
        func frameSize(_ expression: String) -> Int {
            let inner: [String: Any] = ["id": 1, "method": "Runtime.evaluate",
                                        "params": ["expression": expression, "returnByValue": true]]
            guard let envelope = try? wrapInTarget(targetId: targetId, envelopeId: 51, inner: inner),
                  let data = try? JSONSerialization.data(withJSONObject: envelope) else { return .max }
            var argument = base
            argument["WIRSocketDataKey"] = data
            guard let body = try? encodePlistMessage(selector: "_rpc_forwardSocketData:",
                                                     argument: argument) else { return .max }
            return encodeFrame(body).count
        }
        guard let expressions = assemblyExpressions(javaScript: WebViewDOM.javaScript,
                                                    budget: budget, frameSize: frameSize) else { return nil }
        for (offset, expression) in expressions.enumerated() {
            // 積む側は短い応答しか返らないので待ちは短くてよい
            guard evaluateExpression(expression, id: 100 + offset, timeout: 5) != nil else { return nil }
        }
        return evaluateExpression(assemblyRunExpression, id: 1, timeout: 15)
    }
}

/// 4byte BE 長 + plist フレームを話す口の共通形。シミュレータ(`SafariInspectorConnection`。
/// unix ソケット直結)と実機(`TLSInspectorConnection`。usbmuxd 越しの TLS)が適合する。
/// **`evaluate` はこの越しにだけ書く** —— ソケットの開け方が違うだけで RPC は共通なので、
/// プロトコル本体(plist メッセージ・Target 包み)を2箇所に重複させない
protocol InspectorTransport: AnyObject {
    func send(_ frame: Data) -> Bool
    func receiveFrame(deadline: Date) -> Data?
    func close()
}

/// WebKit remote inspector の生ソケット(unix domain, SOCK_STREAM)。
/// シミュレータは `init?(path:)` で `/private/var/tmp` 等へ直接繋ぐ。実機は
/// `PhysicalSafariInspector` が usbmuxd 経由で確立済みの fd を `init(fd:)` で渡す
/// (webinspectord が平文の場合のみ。TLS が要る場合は `TLSInspectorConnection` を使う)
final class SafariInspectorConnection: InspectorTransport {
    private let fd: Int32
    private var buffer = Data()

    /// 接続済みの fd をそのまま使う。**受信タイムアウトの設定と close の責務だけ持つ**
    /// (接続の確立・fd の所有権移譲は呼び出し側の契約)
    init(fd: Int32) {
        self.fd = fd
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    convenience init?(path: String) {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { Darwin.close(sock); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { Darwin.close(sock); return nil }
        // **受信はここで一律 0.5秒でタイムアウトさせる**: `receiveFrame` の待ちループが
        // deadline を細かくチェックできるようにするため(1回の recv がデッドラインを超えて
        // ブロックし続けるのを防ぐ)。`init(fd:)` 側でも同じ設定をやり直す(冪等)
        self.init(fd: sock)
    }

    func send(_ frame: Data) -> Bool {
        guard !frame.isEmpty else { return true }
        return frame.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < frame.count {
                let n = write(fd, base.advanced(by: sent), frame.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// 1フレーム分の本体(plist)を読む。**内部バッファに貯めてから `extractFrame` で切り出す**
    /// —— recv の呼び出し境界は 4byte 長プレフィクスの境界と一致しない(タイムアウトが
    /// フレーム途中に落ちることがある)ので、生の read をそのままフレームへ対応づけると
    /// 境界がずれて以降ずっと壊れる。純粋な `extractFrame` を使い回すことで境界判定を一本化する
    func receiveFrame(deadline: Date) -> Data? {
        while Date() < deadline {
            if let (body, rest) = SafariWebInspector.extractFrame(from: buffer) {
                buffer = rest
                return body
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = chunk.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, raw.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                return nil // EOF(相手が切断)
            }
            // n < 0: SO_RCVTIMEO によるタイムアウト等。deadline まで待ち続ける
        }
        return nil
    }

    /// **二度閉じない**(2026-08-13 のレビュー指摘)。呼び出し側は `defer { close() }` を打つので
    /// close → deinit で同じ fd を2回閉じることになり、**その間に別スレッドが開いた無関係な
    /// fd を閉じ得る**(このプロセスはソケット・パイプを並行に開く)。
    /// `TLSInspectorConnection` は同じ理由で最初から `closed` を持っている
    private var closed = false

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    deinit { close() }
}
