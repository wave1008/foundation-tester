// fleetest の MCP サーバ(stdio / JSON-RPC 2.0、依存ゼロの自前実装)。
// Claude Code などの MCP クライアントに、シミュレータ/エミュレータの操作と
// フロー実行をツールとして公開する。
//
// 役割分担の思想:
// - エージェント(クライアント側)が「知能」: 探索・判断・テスト作成
// - このサーバと Flow DSL が「決定性」: 操作・再生・検証
// explore 相当はツールとして提供しない — スナップショットと操作プリミティブがあれば
// クライアントのエージェント自身が探索できるため。

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

@main
struct FleetestMCP {
    static func main() async {
        LedgerWriteRole.enableForProduction()
        let server = MCPServer()
        await server.run()
    }
}

final class MCPServer {

    /// engineKey ごとの記憶の唯一の保存先(欄の意味は DeviceSession.swift)。下の窓はここを見るだけ
    var sessions: [String: DeviceSession] = [:]
    var drivers: SessionMap<AppDriver> { SessionMap(server: self, path: \.driver) }
    var engines: SessionMap<String> { SessionMap(server: self, path: \.engine) }
    var lastSnapshots: SessionMap<SnapshotResponse> { SessionMap(server: self, path: \.lastSnapshot) }
    var refGenerations: SessionMap<[(base: Int, snapshot: SnapshotResponse, actionCount: Int)]> { SessionMap(server: self, path: \.refGenerations) }
    var sessionActionCounts: SessionMap<Int> { SessionMap(server: self, path: \.sessionActionCount) }
    var lastTapTargets: SessionMap<ElementInfo> { SessionMap(server: self, path: \.lastTapTarget) }
    var knownScreens: SessionMap<FTRect> { SessionMap(server: self, path: \.knownScreen) }
    var uiFrameworkHints: SessionMap<AppUIFramework> { SessionMap(server: self, path: \.uiFrameworkHint) }
    var udids: SessionMap<String?> { SessionMap(server: self, path: \.udid) }
    var launchedBundleIDs: SessionMap<String> { SessionMap(server: self, path: \.launchedBundleID) }
    var launchTimestamps: SessionMap<Date> { SessionMap(server: self, path: \.launchTimestamp) }
    var toolStoppedBundleIDs: SessionMap<String> { SessionMap(server: self, path: \.toolStoppedBundleID) }
    var installedPackagePaths: SessionMap<String> { SessionMap(server: self, path: \.installedPackagePath) }
    var lastScreenshots: SessionMap<StaleFrameDetector.Record> { SessionMap(server: self, path: \.lastScreenshot) }
    var rememberedSnapshotFilters: SessionMap<[String: Bool]> { SessionMap(server: self, path: \.rememberedSnapshotFilters) }
    var sheetRescueFutile: SessionMap<Set<String>> { SessionMap(server: self, path: \.sheetRescueFutile) }
    var pendingWarnings: SessionMap<[String]> { SessionMap(server: self, path: \.pendingWarnings) }
    var lastScreenProbe: SessionMap<(fingerprint: Int, warning: String)> { SessionMap(server: self, path: \.lastScreenProbe) }
    var connections: SessionMap<String> { SessionMap(server: self, path: \.connection) }
    var connectedPorts: SessionMap<UInt16> { SessionMap(server: self, path: \.connectedPort) }
    var hybridFallbackPorts: SessionMap<UInt16> { SessionMap(server: self, path: \.hybridFallbackPort) }
    var connectedAndroidSerials: SessionMap<String> { SessionMap(server: self, path: \.connectedAndroidSerial) }
    var versionSkew: SessionMap<String> { SessionMap(server: self, path: \.versionSkew) }
    var uiFrameworkUnknownPending: SessionFlags { SessionFlags(server: self, path: \.uiFrameworkUnknownPending) }
    var systemAlertProbePending: SessionFlags { SessionFlags(server: self, path: \.systemAlertProbePending) }
    var backgroundedByNavigate: SessionFlags { SessionFlags(server: self, path: \.backgroundedByNavigate) }
    var webPageCeilingLatched: SessionFlags { SessionFlags(server: self, path: \.webPageCeilingLatched) }
    var preparedPhysicalAndroid: SessionFlags { SessionFlags(server: self, path: \.preparedPhysicalAndroid) }
    var bridgeRecoveryFailed: SessionFlags { SessionFlags(server: self, path: \.bridgeRecoveryFailed) }

    /// 探索中の操作列(ft_draft_scenario の材料。InteractionLog 参照)
    var interactions = InteractionLog()
    /// 次の新しい世代に割り当てる base。**セッションに1つ**(engineKey ごとではない)・**単調増加のみ**。
    ///
    /// **機ごとに持ってはいけない**(2026-08-13 に実機で踏んだ): engineKey ごとに 0 から始めると
    /// **2台を触ったセッションで ref 番号が両機で衝突する**。実測(E2EAppCMP・iOS 2台)——
    /// 機A の ref 10 は `#row_30`、機B の ref 10 は `#btn_item_1` で、機A の木を見て採った
    /// `ft_tap ref: 10` を `port:` だけ機B にして撃つと、**警告も拒否も無く成功して**
    /// 機B の `#btn_item_1` を叩き、状態が `result=item3` → `result=item1` に変わった。
    /// どちらも button なので**もっともらしく成功する**のが最悪の形。
    /// セッション全体で単調増加にすれば、他機の ref は世代のどこにも無いので
    /// `RefGuard` が `.gone` で断る(番号が衝突しない = 黙って別物に当たれない)。
    /// **`forgetDeviceState` はこれを消さない** —— 捨てた番号を再配布しないため
    var nextRefBase = 0
    /// 保持する世代数の上限。**5**: 「1つ前の木」しか見ない従来より十分に厚いが、
    /// 無制限にするとセッションが長引くほど探索コストと保持量が線形に増える
    static let maxRefGenerations = 5
    /// 台の印(`MCPDeviceLease`)と run の lease を読む場所(run と同じ `RepoRoot/.fleetest`)。
    /// nil = 印を置かない。**差し替えドライバ(テスト)では既定 nil** —— 既定のままだと偽の台の印を本物の
    /// `.fleetest/` へ書き散らす(実際に `mcp-emulator-5554.lease` が残った)。テストは一時フォルダを渡す
    var deviceLeaseStateDir: URL?
    /// **セッション(プロセス)を通じて1度だけ**満額で説明した注記の鍵。以後は短縮形にする
    /// (`once` 参照)。engineKey を跨いで共有する — 説明の中身は接続先に依らず同じ文なので、
    /// 機ごとに割ると同じ長文が機の数だけ繰り返される
    var explainedNotes: Set<String> = []
    /// 応答の書き出し口。**stdout は JSON-RPC 専用**(診断を混ぜるとクライアントのパースが壊れる)
    let write: (Data) -> Void
    /// ドライバ生成の差し替え口。nil = 実デバイスを解決する(既定)
    let makeDriver: ((_ args: [String: Any]) async throws -> AppDriver)?
    /// スナップショットの `#id` を台帳へ落とす口。**テストは必ず差し替える**
    /// (既定は実プロジェクトの `.fleetest/` へ書くので、テストが利用者の資産を汚す)
    let recordSnapshot: (_ snapshot: SnapshotResponse, _ platform: String,
                                 _ args: [String: Any]) -> Void

    /// 差し替えドライバの経路でも版ズレのゲートを通すか(テスト用。既定 off。
    /// 実運用の経路は常に通る。理由は driver(_:) のコメント)
    let checksVersionOnInjectedDriver: Bool

    /// snapshotAfter の settle-lite が挟む待ち(秒)。**テストは 0 にする**
    /// (snapshotAfterBody 参照。既定 0.4 は実測に基づく調整値ではなく、1回だけの短い猶予)
    var settleWaitSeconds: Double = 0.4

    /// ft_rotate の整定ポーリングの締め切り(秒)。**テストは 0 にする** —— cap
    /// (rotationSettleDeadlineSeconds ÷ pollInterval)が0本になり、
    /// 一度も整定しないフェイクドライバでもすぐに「未整定」の注記へ落ちる。
    /// 既定は `FTCore.RotationSettle.deadlineSeconds`(ブリッジ側 POST /rotate の整定予算と同じ)——
    /// 従来は変化待ちの `changeSettleRereads`(3)×`settleWaitSeconds`(0.4s)=1.2秒を
    /// 流用していたが、実機 iPhone ではレイアウトが収まる前に予算が尽きていた
    var rotationSettleDeadlineSeconds: Double = RotationSettle.deadlineSeconds


    init(write: @escaping (Data) -> Void = { ConsoleOut.out($0) },
         makeDriver: ((_ args: [String: Any]) async throws -> AppDriver)? = nil,
         recordSnapshot: ((_ snapshot: SnapshotResponse, _ platform: String,
                           _ args: [String: Any]) -> Void)? = nil,
         checksVersionOnInjectedDriver: Bool = false) {
        self.write = write
        self.makeDriver = makeDriver
        self.recordSnapshot = recordSnapshot ?? MCPServer.recordSelectors
        self.checksVersionOnInjectedDriver = checksVersionOnInjectedDriver
        self.deviceLeaseStateDir = makeDriver == nil
            ? (try? RepoRoot.find())?.appendingPathComponent(".fleetest") : nil
    }

    // MARK: - メインループ(stdio: 改行区切り JSON-RPC)

    func run() async {
        // **黙らせた注記は起動時に名乗る**(A/B の陽性対照)。差が出なかったときに
        // 「変更が無効だった」と「実験が無効だった」を区別できないと、Scripts/mcp-bench.sh の
        // 結論は毎回どちらとも取れる。綴り違いの鍵は落ちていないので必ず名指しする
        if !NoteCatalog.disabled.isEmpty {
            Self.logStderr("FT_MCP_NOTES_OFF: silencing "
                + NoteCatalog.disabled.sorted().joined(separator: ", "))
        }
        let unknownNoteKeys = NoteCatalog.unknownDisabledKeys()
        if !unknownNoteKeys.isEmpty {
            Self.logStderr("FT_MCP_NOTES_OFF: NOT a note key (ignored): "
                + unknownNoteKeys.joined(separator: ", "))
        }
        // 明細だけ畳む指定も同じ規律で名乗る(A/B の陽性対照。NoteCatalog.brief の宣言参照)
        if !NoteCatalog.brief.isEmpty {
            Self.logStderr("FT_MCP_NOTES_BRIEF: folding the per-element detail of "
                + NoteCatalog.brief.sorted().joined(separator: ", "))
        }
        let unknownBriefKeys = NoteCatalog.unknownDisabledKeys(NoteCatalog.brief)
        if !unknownBriefKeys.isEmpty {
            Self.logStderr("FT_MCP_NOTES_BRIEF: NOT a note key (ignored): "
                + unknownBriefKeys.joined(separator: ", "))
        }
        while let line = readLine(strippingNewline: true) {
            // **壊れた行でループを抜けない**: 1行の不正でサーバが死ぬとセッションごと落ちる
            guard let message = Self.parseMessage(line) else { continue }
            await handle(message)
        }
        // stdin EOF = セッションの終わり。台の印を残すと、使っていない台を run が避け続ける
        if let deviceLeaseStateDir {
            MCPDeviceLease.removeAll(stateDir: deviceLeaseStateDir, pid: ProcessInfo.processInfo.processIdentifier)
        }
    }

    /// 1行を JSON-RPC メッセージとして解釈する。空行・非 JSON・JSON オブジェクトでないものは nil
    static func parseMessage(_ line: String) -> [String: Any]? {
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func handle(_ message: [String: Any]) async {
        let method = message["method"] as? String ?? ""
        let id = message["id"]

        // id なしは notification(initialized 等)— 応答しない
        guard id != nil else { return }
        // **`"id": null` は notification ではなく無効要求**(JSON-RPC 2.0 / MCP は id に null を許さない)。
        // 実行してから null 宛てに result を返すと、どの要求の答えかクライアントが突き合わせられない
        if id is NSNull {
            reply(id: nil, error: ["code": -32600, "message": "invalid request: id must not be null"])
            return
        }

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": Self.negotiatedProtocolVersion(
                    requested: (message["params"] as? [String: Any])?["protocolVersion"] as? String),
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "fleetest", "version": "0.1.0"],
                "instructions": Self.serverInstructions,
            ])
        case "ping":
            reply(id: id, result: [String: Any]())
        case "tools/list":
            reply(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let content = try await call(tool: name, args: args)
                reply(id: id, result: ["content": content, "isError": false])
            } catch {
                // FTCore 由来の文には CLI のフラグ(`--project`)が書いてある。MCP の読み手が
                // 渡せるのは同名の**引数**なので、ここで一度だけ言い換える(MCPMessageText)
                reply(id: id, result: [
                    "content": [["type": "text",
                                 "text": "Error: "
                                    + MCPMessageText.forMCP(error.localizedDescription)]],
                    "isError": true,
                ])
            }
        default:
            reply(id: id, error: ["code": -32601, "message": "method not found: \(method)"])
        }
    }

    /// このサーバが実装している MCP の版。**2025-03-26 は入れない** —— その版は JSON-RPC バッチの
    /// 受信を必須にするが、parseMessage は配列を捨てる(バッチを送るクライアントが永久に待つ)。
    /// 2025-06-18 はバッチを廃止し、tools だけのサーバに追加の必須事項は無い
    static let supportedProtocolVersions = ["2024-11-05", "2025-06-18"]

    /// 版交渉: 対応している版の要求はその版、それ以外(未対応・未指定)は自分の最新を返す。
    /// 要求をそのまま echo しない(対応していない版の必須事項まで名乗ることになる)
    static func negotiatedProtocolVersion(requested: String?) -> String {
        if let requested, supportedProtocolVersions.contains(requested) { return requested }
        return supportedProtocolVersions.last!
    }

    /// JSON の `null` は JSONSerialization で NSNull になり、`args["x"] != nil` 型の判定を
    /// 「指定あり」に倒す(waitFor / scrollFrame / url / ref / duration の判定がそれ)。
    /// 省略欄に null を埋めるクライアントのために、**call() の入口で1回だけ**落とす ——
    /// 判定を1箇所ずつ値の型に直す形にすると、次に足した判定が同じ穴を再生産する。
    /// 見るのは最上位だけ(配列の中の null は各引数の `as? [Int]` が既に弾く)
    static func droppingNullArguments(_ args: [String: Any]) -> [String: Any] {
        args.filter { !($0.value is NSNull) }
    }

    private func reply(id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func reply(id: Any?, error: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        write(data)
    }




    /// このプロセスの寿命だけ生きる、最後に**明示**された iOS 宛先(port + udid)。
    /// **更新は udid/port のどちらかが引数にあった呼び出しの、解決成功後だけ**
    /// (自動解決の結果は混ぜない)。**使用は udid/port が両方とも無かった呼び出しだけ**
    /// (driver(_:) 参照。純粋な判定は iosExplicitWithMemory/iosMemoryAfterResolve)
    var lastExplicitIOSTarget: (port: UInt16, udid: String?)?
    /// Android 版の同じ記憶。同じ規律(androidExplicitWithMemory/androidMemoryAfterResolve)
    var lastExplicitAndroidSerial: String?
    /// このセッションで明示解決された iOS 宛先(port)の**延べ集合**。
    /// **lastExplicitIOSTarget との違い**: あちらは「省略呼び出しが実際にどこへ行くか」に使う
    /// 直近1件、こちらは「省略呼び出しが曖昧かどうか」の判定材料(2件以上あれば
    /// finishingFold が毎回注記する。1台しか触っていなければ従来どおり初回だけ)。
    /// 更新は lastExplicitIOSTarget と同じ箇所・同じ条件(driver(_:) 参照)。
    /// forgetConnection が死んだポートを取り除く(消えた機は候補として名乗る意味が無い)
    var seenExplicitIOSPorts: Set<UInt16> = []
    /// Android 版の同じ延べ集合(serial)
    var seenExplicitAndroidSerials: Set<String> = []
    /// **このセッションが一度でも宛先を名指ししたか**(2026-08-13。一度立ったら降ろさない)。
    /// 上の2つの集合とは別に要る —— あちらは forgetConnection が死んだ機を取り除くので、
    /// 名指しした機が全部死ぬと空になり、**新しいセッションと見分けが付かなくなる**。
    /// その状態で省略呼び出しをブリッジ探索へ落とすと、名指ししていない機を操作する
    /// (lostTargetFold の doc に実測した事故)
    var everNamedIOSTarget = false
    /// Android 版の同じフラグ
    var everNamedAndroidTarget = false
    /// **udid/port/serial を全部省略した呼び出しがどちらの platform の記憶を見るか**
    ///。lastExplicitIOSTarget/lastExplicitAndroidSerial は platform ごとに
    /// 分かれているだけで「どちらが最後に明示されたか」を持たないため、Android を明示した
    /// 直後に platform も省略した呼び出しが(既定の "ios" に負けて)iOS の記憶へ迷い込んでいた。
    /// 更新は iOS/Android どちらかの記憶が実際に更新された(= 利用者が明示した)ときだけ
    /// (foldInRememberedDevice が platform 明示時はこれを読まない)
    var lastExplicitPlatform: String?
}

extension MCPServer {
    /// `port` 引数を UInt16 に畳む。無指定は nil。**範囲外・非整数は MCPError** ——
    /// `UInt16.init` は 65535 超・負数で trap し、エージェントの typo 1 回でサーバごと落ちる。
    /// 値域は `ArgumentBounds.numeric["port"]` を引く(1〜65535 を2箇所に持たない)
    static func portArgument(_ args: [String: Any]) throws -> UInt16? {
        guard let value = try intArgument(args, "port") else { return nil }
        let bound = ArgumentBounds.numeric["port"] ?? .unbounded
        let low = Int(bound.min ?? 1), high = Int(bound.max ?? 65535)
        guard let port = UInt16(exactly: value), value >= low, value <= high else {
            throw MCPError("port must be an integer between \(low) and \(high) (got \(value))")
        }
        return port
    }

    /// **数値引数の唯一の取り出し口**(Int/Double 共通)。全ての `args["…"] as? Int` /
    /// `as? Double` はここを通す(`NumericArgumentSourceScanTests` が直読みの再混入を検出)。
    /// 無指定は nil(従来どおり)。**型が違えば断る**(寛容化しない) —— MCP クライアントは
    /// JSON Schema が integer/number でも実際に文字列で送ることがあり(実測)、黙って
    /// `as?` を失敗させると呼び手は「値が無い」と区別できないまま、tap の ref なら x/y
    /// 座標フォールバックのような**より危険な**経路へ落ちる。"8" と "8.5" のような境界を
    /// 解釈で割ることもしない(文字列から数値への変換規則を1つ選ぶこと自体が寛容化)。
    /// **型が合っていても値域(`ArgumentBounds`)を外れれば同じく断る** —— 0/負・上限超えは
    /// 従来ここを黙って通り抜けていた(実地: `maxElements:0`・`maxSwipes:-3` 等)
    static func intArgument(_ args: [String: Any], _ key: String) throws -> Int? {
        guard let raw = args[key] else { return nil }
        guard let value = raw as? Int else {
            throw MCPError(numericArgumentTypeError(key: key, raw: raw, expected: "an integer"))
        }
        if let violation = ArgumentBounds.violation(key, Double(value)) { throw MCPError(violation) }
        return value
    }

    /// Double 版(同じ規律。値域も同じく効く)
    static func doubleArgument(_ args: [String: Any], _ key: String) throws -> Double? {
        guard let raw = args[key] else { return nil }
        guard let value = raw as? Double else {
            throw MCPError(numericArgumentTypeError(key: key, raw: raw, expected: "a number"))
        }
        if let violation = ArgumentBounds.violation(key, value) { throw MCPError(violation) }
        return value
    }

    /// **文字列引数の唯一の取り出し口(省略可)**。型が違えば断る(intArgument と同じ規律)。
    /// `ArgumentBounds.mustNotBeEmpty` に載っている鍵は、明示された空文字・空白のみも断る ——
    /// 省略(キー自体が無い)はここを通らない(呼び手ごとの既定に委ねる)。
    /// `emptyHint` は空文字を断るときだけ末尾に付け足す呼び手向けの補足
    /// (例: 「省略すればこのセッションが繋がっているアプリを使う」)
    static func stringArgument(_ args: [String: Any], _ key: String,
                               emptyHint: String? = nil) throws -> String? {
        guard let raw = args[key] else { return nil }
        guard let value = raw as? String else {
            throw MCPError(stringArgumentTypeError(key: key, raw: raw))
        }
        if let violation = ArgumentBounds.emptyViolation(key, value) {
            throw MCPError(emptyHint.map { "\(violation) — \($0)" } ?? violation)
        }
        return value
    }

    /// 必須版: 欠落は `"\(key) is required"`。型違い・空文字は `stringArgument` と同じ文言
    static func requiredStringArgument(_ args: [String: Any], _ key: String) throws -> String {
        guard let raw = args[key] else { throw MCPError("\(key) is required") }
        guard let value = raw as? String else {
            throw MCPError(stringArgumentTypeError(key: key, raw: raw))
        }
        if let violation = ArgumentBounds.emptyViolation(key, value) { throw MCPError(violation) }
        return value
    }

    private static func stringArgumentTypeError(key: String, raw: Any) -> String {
        "\(key) must be a string (got \(describeArgumentValue(raw))) — pass a JSON string, not a number"
    }

    /// ft_terminate/ft_logs の bundleId のように「省略すればこのセッションが繋がっている
    /// アプリを使う」引数が空文字を断るときの補足文言(1箇所に集約 — 3箇所で複製しない)
    static let attachedAppEmptyHint = "omit it to use the app this session is attached to"

    private static func numericArgumentTypeError(key: String, raw: Any, expected: String) -> String {
        "\(key) must be \(expected) (got \(describeArgumentValue(raw))) — pass a JSON number, not a quoted string"
    }

    /// エラー文に渡された値の**型が分かる形**で埋め込む。素の `\(raw)` は文字列 "8130" を
    /// 数値の 8130 と見分けが付かない形で出す(この不具合の実物)
    /// 整数の**配列**を取る引数(`drop` / `scenes` = 1 始まりのステップ番号)。
    /// **要素が1つでも整数でなければ断る** —— `compactMap { $0 as? Int }` で落とすと、
    /// 指定した番号が黙って効かない(刈り込みや切れ目が入らないのに成功したように見える)
    static func intArrayArgument(_ args: [String: Any], _ key: String) throws -> [Int]? {
        guard let raw = args[key] else { return nil }
        guard let items = raw as? [Any] else {
            throw MCPError("\(key) must be an array of integers (got \(describeArgumentValue(raw)))"
                + " — pass JSON numbers, not quoted strings")
        }
        return try items.enumerated().map { index, item in
            guard let value = item as? Int else {
                throw MCPError("\(key)[\(index)] must be an integer"
                    + " (got \(describeArgumentValue(item))) — pass JSON numbers,"
                    + " not quoted strings")
            }
            return value
        }
    }

    /// **`private` ではない** —— MCPServer+Snapshot.swift の `scrollTo` が selector の型エラー文に
    /// 同じ書式を使う(既存の必須+空文字の文言はそちらに残したまま、型検査だけ揃える)
    static func describeArgumentValue(_ raw: Any) -> String {
        switch raw {
        case let value as String: return "the string \"\(value)\""
        case let value as Bool: return "the boolean \(value)"
        case is [Any]: return "an array"
        case is [String: Any]: return "an object"
        case is NSNull: return "null"
        default: return "\(raw)"
        }
    }
}

struct MCPError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
