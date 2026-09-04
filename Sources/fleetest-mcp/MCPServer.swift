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
        let server = MCPServer()
        await server.run()
    }
}

final class MCPServer {

    var drivers: [String: AppDriver] = [:]
    /// drivers と同じキーで「実際に主となったエンジン」を覚える。iosEngineHint がこれで
    /// 助言を出し分ける(引数からは決まらない: profile 無しでも in-app を掴めば hybrid)
    var engines: [String: String] = [:]
    /// 探索中の操作列(ft_draft_scenario の材料。InteractionLog 参照)
    var interactions = InteractionLog()
    /// drivers と同じキーで**直前にエージェントへ返した木**を覚える。ref を撃つ直前に
    /// 撮り直して同じ要素を引き直すための起点(RefGuard 参照)。
    /// **ref はスナップショットごとに振り直される**ので、番号ではなく要素の同一性で照合する
    var lastSnapshots: [String: SnapshotResponse] = [:]
    /// **ref の世代管理**。ブリッジは撮るたびに ref を振り直すので、
    /// 「1つ前の木」しか起点にしない `lastSnapshots` だけでは、それより前の snapshot の ref を
    /// 撃たれたときに「たまたま同じ番号を持つ別要素」へ黙って当たる(実害: ft_scroll_to の後に
    /// 旧 ref [42](戻るボタン)を叩いたら新しい木の [42](静的テキスト「料金:」)に当たった)。
    /// MCP 層で ref にオフセット(`base`)を掛け、セッション内で全世代の ref を一意にする ——
    /// ブリッジには一切触らない。古い順に並び、**直近5世代だけ**保持する(adoptSnapshot 参照)
    var refGenerations: [String: [(base: Int, snapshot: SnapshotResponse)]] = [:]
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
    /// scroll_to の空打ちゲート用 uiFramework(engineKey ごと)。**成功だけ**記憶する —
    /// 失敗(nil)を覚えると、suspend 中の1回のタイムアウトで判定がセッション全体に固定される
    var uiFrameworkHints: [String: String] = [:]
    /// 特定できたシミュレータの udid(engineKey ごと)。xcuitest のマーカー判定に使う
    var udids: [String: String?] = [:]
    /// drivers と同じキーで**最後に ft_launch した bundleID**を覚える。
    ///
    /// **Android のブリッジは session を前面ウィンドウから採る**(`SnapshotBuilder` の
    /// `root.getPackageName()`)。つまり back でアプリを出ると session がその場で別アプリに
    /// 差し替わり、`backgroundedSessionNote`(session が前面か)は**構造上まったく発火しない**。
    /// E2E の 4 SUT は `#id`・ラベルが共通契約なので、木を見ても入れ替わりに気付けない
    /// (2026-08-06 の探索で決定的に再現: `ft_launch com.ftester.e2e.android` → `back` 1回で
    /// 以後の snapshot が `com.ftester.e2e.flutter` の木になった)。
    /// **ホスト側で「起動したアプリ」を覚えて突き合わせる**のが唯一の検知経路。
    var launchedBundleIDs: [String: String] = [:]
    /// drivers と同じキーで**最後に ft_install した packagePath**を覚える(engineKey ごと)。
    /// **実機の ft_clear_app_data が使う** —— devicectl には clearAppData の同等手段が無く
    /// (BridgeClient.clearAppData の 501)、代わりに uninstall+install で再現するのに要る
    var installedPackagePaths: [String: String] = [:]
    /// **launch 系ツール(ft_launch/ft_open_url/ft_clear_app_data/ft_install)の直後**、次の
    /// ft_snapshot で一度だけ `GET /systemalert` を確かめるための予約(engineKey ごと)。
    /// DSL 側の `StepExecutor.systemAlertProbePending`(FTRuntime.swift の `noteAppLaunched`)と
    /// 同じ設計 —— launch 直後は SpringBoard の許可アラートが出やすいが、毎 snapshot 払うと
    /// 高頻度な MCP のポーリングで往復が倍になる。**springboard 自身への ft_launch では立てない**
    /// (そちらは意図してアラートを読みに行く経路なので、覆いではなく本来の画面)。
    /// snapshotBody が読んで消費(先に消してから probe)し、forgetDeviceState / ft_terminate で捨てる
    var systemAlertProbePending: Set<String> = []
    /// **このセッションが `ft_navigate home` / `appSwitcher` でアプリを背面へ送ったまま**か
    /// (engineKey ごと)。次の ft_launch で消す。
    ///
    /// なぜ「聞く」だけでは足りないか: `backgroundedSessionNote(_:driver:)` は `/appstate` へ
    /// 聞くが、**実機 iPhone 13 の実測でその照会が前面と答えた**(ホーム画面が出ていて、
    /// スクリーンショットでも確認済み)。木も session もアプリのままなので、ツールが送った
    /// 事実だけが唯一の確かな材料になる。**プラットフォームの答えに上書きさせない**
    var backgroundedByNavigate: Set<String> = []
    /// ft_screenshot の鮮度判定用(engineKey ごと)。**静止画面の2連続 ft_screenshot は PNG が
    /// バイト単位で同一**(2026-08-10 実測: Android 83,028B×2 / iOS 95,076B×2)—— これが成り立つから
    /// 「木は変わったのに絵が前回と同一 = 古いフレームを返し続けている」と言える(treeFingerprint の
    /// 前後比較単独では拾えなかった動機の事象: 木は新しいのに絵だけ古い)
    var lastScreenshots: [String: StaleFrameDetector.Record] = [:]
    /// ft_snapshot で**明示された** interactiveOnly/expandBulk(engineKey ごと)。呼ばれるたびに
    /// 丸ごと置き換える(省略されたキーは記憶から消える)。snapshotAfterBody が、呼び出し側の
    /// args に無いキーだけこれで補う — 明示した値が常に優先(snapshotAfterBody 参照)
    var rememberedSnapshotFilters: [String: [String: Bool]] = [:]
    /// **切り詰められた web ページを見たデバイス**(engineKey)。以後の読みは最初から要素上限の
    /// 天井で撮る(`needsWebPageCeiling`)。2枚払うのはラッチした1回だけ ——
    /// 毎回「撮る→切り詰めを見て撮り直す」だと、waitFor のポーリングで読みが倍になる
    var webPageCeilingLatched: Set<String> = []
    /// **シート展開救済が効かないと分かった画面**(engineKey ごと・木の指紋の集合。
    /// `sheetRescueKey` 参照)。同じ画面での2回目以降の ft_scroll_to は救済を撃たずに即返す
    var sheetRescueFutile: [String: Set<String>] = [:]
    /// プロファイル解決で出た警告(未解決のデバイス名など)。**次に返す応答へ1度だけ**混ぜる。
    /// stderr だけに出していたときは MCP クライアントに一切届かなかった
    var pendingWarnings: [String: [String]] = [:]
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

    /// ref を撃つ直前の覆い探針(`/systemalert` 等・`screenNotRepresentedWarning`)を
    /// 木の指紋ごとに覚える(engineKey ごと)。**健全性の上限**: 木がバイト同一のまま
    /// 覆う面が出た/消えた画面(静止画面へ出た Control Center 等)は、次に木が変わるまで
    /// 再確認しない —— 見逃しはそこまでに限られる(verifiedRef 参照)
    var lastScreenProbe: [String: (fingerprint: Int, warning: String)] = [:]

    init(write: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) },
         makeDriver: ((_ args: [String: Any]) async throws -> AppDriver)? = nil,
         recordSnapshot: ((_ snapshot: SnapshotResponse, _ platform: String,
                           _ args: [String: Any]) -> Void)? = nil,
         checksVersionOnInjectedDriver: Bool = false) {
        self.write = write
        self.makeDriver = makeDriver
        self.recordSnapshot = recordSnapshot ?? MCPServer.recordSelectors
        self.checksVersionOnInjectedDriver = checksVersionOnInjectedDriver
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

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": (message["params"] as? [String: Any])?["protocolVersion"] ?? "2024-11-05",
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


    /// 接続先の宛先(ft_status が見せる)。**#2/#5 の取り違えは「今どこに繋がっているか」が
    /// 見えないまま起きる** —— 既定 8123 が死んでいても、はぐれエミュレータを掴んでいても、
    /// 応答だけ見ると正常に見える
    var connections: [String: String] = [:]
    /// 掴んでいる iOS ブリッジのポート(engineKey ごと)。**`connections` の文字列から読み解かない**
    /// —— 表示用の文と機械判定を同じ文字列に相乗りさせると、表記を整えるたびに判定が壊れる。
    /// タイムアウト時にそのポートがまだ生きているかを確かめる `connectionLostHint` が使う
    var connectedPorts: [String: UInt16] = [:]
    /// 掴んでいる Android ブリッジの serial(engineKey ごと)。iOS の `connectedPorts` と同じ理由で
    /// `connections` の表示文字列からは読み解かない —— 直接指定は "serial <serial>"、profile
    /// 経由は "<device name> serial <serial>" と経路ごとに書式が違い、文字列切り出しに頼ると
    /// profile 経由だけ判定から漏れる(2026-08-14 に実際に踏んだ)
    var connectedAndroidSerials: [String: String] = [:]

    /// 版ズレの内容(engineKey ごと)。ft_status が「失敗するが理由を返す」ために覚えておく
    var versionSkew: [String: String] = [:]

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

struct MCPError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
