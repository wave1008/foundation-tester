// MCPServer+ConnectionLoss.swift
// 接続喪失時のヒント文言とブリッジの生死判定。本体は MCPServer.swift

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// **経路の振り分けは記録(`connectedPorts`/`connectedAndroidSerials`)で決め、表示ラベルの
    /// 接頭辞では決めない**: `connections[key]` は表示用で、profile 経由の書式
    /// ("<device name> port/serial <値>")は "port"/"serial " のどちらの接頭辞にも一致しない ——
    /// 直接指定と profile とで判別条件を分けると、profile 経由はどちらの回復ハンドラにも
    /// 一度も入らず、死んだブリッジへ永久に再ダイヤルし続ける(実機の陽性対照で確認)
    func connectionLostHint(_ error: Error, args: [String: Any]) async -> String {
        // 差し替えドライバ(テスト)では走査しない = 実ポートを叩かない
        guard makeDriver == nil else { return "" }
        let key = Self.engineKey(args)
        guard let connection = connections[key] else { return "" }
        if connectedPorts[key] != nil {
            return await iosConnectionLostHint(error, key: key, connection: connection)
        }
        if let serial = connectedAndroidSerials[key] {
            return await androidConnectionLostHint(error, key: key, connection: connection, serial: serial)
        }
        return ""
    }

    /// iOS(port 経由のブリッジ)の死活。Android には無い判定材料(BridgeDiscovery.isBound/scan)を
    /// 使うので、判定そのものを共有しない(androidConnectionLostHint 参照)
    func iosConnectionLostHint(_ error: Error, key: String, connection: String) async -> String {
        switch error {
        case DriverError.bridgeConnectionRefused:
            // 接続拒否は「誰も待受していない」が確定しているので、走査は今の状況を添えるだけ
            let running = await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
            return connectionLostAndForget(key: key, connection: connection, running: running)
        case DriverError.bridgeUnreachable:
            // **タイムアウトは死を意味しない**(2026-08-12 の実アプリ監査で踏んだ): 素の文言は
            // 「未起動 / 遅い / suspend」の3択を並べるだけで、直後に ft_status を撃つと
            // 「そのポートにブリッジが無い」と一意に答えられた —— 判定材料はあるのに
            // 操作系が使っていなかった。**確かめてから断定する**: 走査してポートが消えていれば
            // 死亡と言い切り、生きていれば何も足さない(遅い/suspend の可能性が残るため、
            // 素の3択メッセージのままにする)
            guard let port = connectedPorts[key] else { return "" }
            let repoRoot = try? RepoRoot.find()
            // **応答なしを死と読まない**(2026-08-12 の別監査で踏んだ、同じ勘違いの再発): scan は
            // 応答しないブリッジを「消えた」と数えるが、busy なブリッジ(XCUITest quiescence は
            // 実測33.7秒 /status 無応答・tap 等の interaction timeout は20秒)は生きたまま scan にも
            // 載らない。**bound(誰かが listen しているか)を verdict へそのまま渡し、production の
            // 判定点を bridgeUnreachableVerdict の1箇所に一本化する**(手前で `if bound { return }`
            // すると verdict の .busy 枝が production から一度も通らず、テストでしか確認できない
            // 判定になる)。
            // **実機では bound だけを信じない**(欠陥④): 到達手段が usb のとき listen しているのは
            // ランナーではなく iproxy(別プロセス)なので、ランナーが死んでも bound は true のまま
            // 残る。pid ファイルの所有プロセス生死(bridgeOwnerAlive)で補強し、「bound を信じてよいか」
            // (trustBound)を verdict と scan 要否の両方で共有する(手書きの条件式を2箇所に置かない)。
            // 信じてよいときだけ走査を省ける(busy なブリッジは scan に載らず判定に使われない)
            let bound = BridgeDiscovery.isBound(port: port, repoRoot: repoRoot)
            let ownerAlive = Self.bridgeOwnerAlive(port: port, repoRoot: repoRoot)
            let running = Self.trustBound(bound: bound, ownerAlive: ownerAlive)
                ? [] : await BridgeDiscovery.scan(excluding: 0, repoRoot: repoRoot)
            switch Self.bridgeUnreachableVerdict(
                bound: bound, ownerAlive: ownerAlive,
                vanished: Self.bridgeVanished(port: port, running: running)) {
            case .busy:
                return Self.bridgeBusyHint(connection: connection, engine: engines[key])
            case .stillUnclear:
                return ""
            case .vanished:
                return connectionLostAndForget(key: key, connection: connection, running: running)
            }
        default:
            return ""
        }
    }

    /// iOS の2分岐(bridgeConnectionRefused/.vanished)の共通尾部(2026-08-12 の掃討): 記憶を
    /// 捨てて、今の状況を添えたメッセージを組む
    func connectionLostAndForget(key: String, connection: String,
                                 running: [BridgeDiscovery.Found]) -> String {
        // **udid は忘れる前に読む**(2026-08-13 のレビュー指摘)。`forgetConnection` は
        // `forgetDeviceState` 経由で `udids[key]` も消すようになったので、後から読むと
        // 常に nil = 「同じ機のブリッジを先に挙げる」案内が**黙って死んでいた**
        let udid = udids[key].flatMap { $0 }
        forgetConnection(key)
        return Self.connectionLostMessage(connection: connection, running: running,
            sameDevice: Self.deviceName(forUDID: udid, in: running))
    }

    /// Android(serial 経由のブリッジ)の死活。**iOS のような安価な「待受しているか」判定が無い**
    /// ので、`AndroidSerialResolver.connectedSerials()`(`adb devices`)への再照会そのものを
    /// 識別材料にする —— adb の失敗文言は経路(clear/install/forward…)ごとに違って狭く確実な
    /// 部分文字列が取れないので、文字列ではなく probe で確かめる。
    /// **forgetConnection の Android 分岐(lastExplicitAndroidSerial の消去)はここが唯一の呼び手**
    /// (2026-08-12 まで到達不能だった —— 死んだ serial への省略呼び出しがセッション中ずっと
    /// 同じ死んだ serial へ再ダイヤルされ続けていた)
    func androidConnectionLostHint(_ error: Error, key: String, connection: String,
                                   serial: String) async -> String {
        switch error {
        case DriverError.bridgeUnreachable, DriverError.bridgeConnectionRefused, DriverError.badResponse:
            break
        default:
            return ""
        }
        // 端末がまだ adb につながっているなら、今回の失敗は別の理由(アプリ側のエラー等)。
        // probe だけで判定するので、広めに構えても実害は「adb devices を1回余計に撃つ」だけ
        guard Self.androidSerialVanished(serial, connected: AndroidSerialResolver.connectedSerials())
        else { return "" }
        forgetConnection(key)
        return "\nThe Android device behind \(connection) is no longer connected (adb devices"
            + " does not list it — unplugged, or the emulator was shut down). Reconnect it, then"
            + " target it again with serial: (or omit it once only one device is connected)."
    }

    /// probe(`adb devices` 相当の一覧)から見てこの serial は消えたか。**走査から切り離した
    /// 純粋関数**(bridgeVanished と同じ理由: 実 adb が要るとテストで判定を壊しても素通しする)
    static func androidSerialVanished(_ serial: String, connected: [String]) -> Bool {
        !connected.contains(serial)
    }

    static func bridgeUnreachableVerdict(
        bound: Bool, ownerAlive: Bool?, vanished: Bool
    ) -> BridgeUnreachableVerdict {
        if trustBound(bound: bound, ownerAlive: ownerAlive) { return .busy }
        return vanished ? .vanished : .stillUnclear
    }

    /// bound(誰かが listen している)をそのまま信じてよいか。**判定はここ1箇所** ——
    /// iosConnectionLostHint(走査を省くかどうか)と bridgeUnreachableVerdict(.busy を返すか)の
    /// 両方がこれを使う。`ownerAlive == false` のときだけ疑う —— `nil`(pid ファイルが無い =
    /// in-app ブリッジ等、判定材料が無い)は疑わない側に倒す(仮想デバイスの in-app 経路を
    /// 巻き添えにしないため)
    static func trustBound(bound: Bool, ownerAlive: Bool?) -> Bool {
        bound && ownerAlive != false
    }

    /// `.fleetest/bridge-<port>.pid`(xcodebuild の pid。BridgeLauncher.pidPath と同じ規約)の
    /// 所有プロセスが生きているか。ファイルが無い/読めない/pid が数値でなければ nil(不明)。
    /// **実機の usb トランスポートでは listen しているのがランナーでなく iproxy(別プロセス)** —
    /// isBound だけではランナー死後も true のままなので、この判定で補強する(欠陥④)
    static func bridgeOwnerAlive(port: UInt16, repoRoot: URL?) -> Bool? {
        guard let repoRoot,
              let pidString = try? String(
                  contentsOf: repoRoot.appendingPathComponent(".fleetest/bridge-\(port).pid"),
                  encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return kill(pid, 0) == 0
    }

    /// bound(誰かが listen している)なポートへ「exited」と言わないための正直な文言。
    /// **forgetConnection も呼ばない**呼び手側の判断とセットで使う(iosConnectionLostHint 参照)。
    /// **エンジンで文面を出し分ける**: in-app/hybrid ブリッジは対象アプリが
    /// 前面のときしか応答しない(kernel が handshake を返すので isBound は true のまま)ので、
    /// XCUITest 向けの「busy・リトライせよ」は永遠に的外れな助言になる
    static func bridgeBusyHint(connection: String, engine: String?) -> String {
        guard engine == "inapp" || engine == "hybrid" else {
            return "\nThe XCUITest runner behind \(connection) did not answer in time, but the"
                + " port is still bound — likely busy (a long-running operation, such as waiting"
                + " for the screen to settle, can block the bridge for tens of seconds). Retry the"
                + " call; the connection was not dropped."
        }
        return "\nThe in-app bridge behind \(connection) is not answering — it only answers while"
            + " the app it is injected into is in the foreground. Bring it back with ft_launch,"
            + " or use this device's xcuitest bridge port instead."
    }

    /// 死んだ接続の udid を、**手元にある scan 結果**から端末名へ引き直す(best-effort)。
    /// 失敗しても黙る —— `connectionLostMessage` の「同じ端末を先に」が効かず、
    /// 通し番号での畳み方に落ちるだけ。
    /// **SimulatorCatalog を再照会しない**: 呼び手は既に `running`(BridgeDiscovery.scan
    /// の結果)を持っており、カタログ名とブリッジ申告名がズレると「同じ機を先頭に」が壊れる
    static func deviceName(forUDID udid: String?, in running: [BridgeDiscovery.Found]) -> String? {
        guard let udid else { return nil }
        return running.first { $0.udid == udid }?.device
    }

    /// タイムアウトのとき「そのブリッジは消えた」と言い切ってよいか。**走査から切り離した
    /// 純粋関数** —— 実ブリッジが要ると、この枝はテストで一度も実行されず、判定を壊しても
    /// 素通しする(`reconcilePort` が 2026-08-09 の変異テストで実際に踏んだのと同じ型)
    static func bridgeVanished(port: UInt16, running: [BridgeDiscovery.Found]) -> Bool {
        !running.contains { $0.port == port }
    }

    /// 掴んでいたドライバは死んでいる。次の呼び出しで解決し直させる。
    /// **記憶(lastExplicitIOSTarget/lastExplicitAndroidSerial)も一致すれば一緒に忘れる**
    ///: resolveIOSPort/resolveAndroidSerial は記憶されたポート/serial を生存確認
    /// なしで返す(driver() 参照)ので、ここで消さないと、死んだ接続の後の省略呼び出しが
    /// 同じ死んだポート/serial へ永久に再ダイヤルし続ける。**internal**(テストが直接呼ぶ)
    func forgetConnection(_ key: String) {
        if let port = connectedPorts[key] {
            if lastExplicitIOSTarget?.port == port { lastExplicitIOSTarget = nil }
            // 消えたポートは「このセッションで触った他の候補」として名乗る意味が無い
            // (rememberedDeviceNote が曖昧さの判定に使う集合。生きているものだけ残す)
            seenExplicitIOSPorts.remove(port)
        }
        // **`connections[key]` の書式から抽出しない**: profile 経由のラベルは
        // "<device name> serial <serial>" で `hasPrefix("serial ")` に一致せず、profile で
        // 触った Android 機は記憶が一度も消えなかった(connectionLostHint と同じ根の欠陥)
        if let serial = connectedAndroidSerials[key] {
            if lastExplicitAndroidSerial == serial { lastExplicitAndroidSerial = nil }
            seenExplicitAndroidSerials.remove(serial)
        }
        forgetDeviceState(key)
    }

    /// engineKey に紐づく状態を**全部**捨てる。
    ///
    /// **なぜ「ドライバだけ」では足りないか**: engineKey は `direct:ios:<port>:<serial>` で、
    /// iOS のポートは**同じセッション中に動く**(監視が別ポートで建て直す。実測: -03 が
    /// 8128→8126、-07 が 8136→8147)。つまり**一度死んだポートが後で別のシミュレータに
    /// 再利用され得る**。`forgetConnection` が drivers/connections/connectedPorts しか
    /// 消していなかったので、そのとき `lastSnapshots` と `refGenerations` は**前の機の木**、
    /// `launchedBundleIDs` は**前の機で起動したアプリ**のまま生き残っていた ——
    /// 古い ref が別の機の木を起点に解決され、`ft_open_url` が前の機のアプリへ配送する。
    /// 出力がずれるだけの記憶(注記・フィルタ)と違い、**これは操作が別物へ届く型**なので
    /// 「キーが指す機が変わったら全部捨てる」を1箇所に固める。
    ///
    /// **`nextRefBase` だけは残す**(単調増加の不変条件)。ここで 0 へ戻すと、捨てた世代と
    /// 同じ base が新しい世代へ再配布され、セッション内で ref が一意という保証が壊れる ——
    /// 世代管理そのものが防いでいる「番号は同じだが別要素」を、後始末の側から作ってしまう。
    ///
    /// **engineKey で引く記憶を新設したらここへ足す**。足し忘れは
    /// `DeviceStateInvalidationTests.testEveryEngineKeyedMemoIsAccountedForHere` が検出する
    /// (`MCPServer.swift` の `[String: …]` を走査して、この関数か `deliberatelyKept` の
    /// どちらにも現れない名前を落とす)—— この後始末は網羅が本体なので、1つ漏れると
    /// 「ほとんど捨てたが1つだけ前の機のまま」という最も分かりにくい形になる
    func forgetDeviceState(_ key: String) {
        drivers[key] = nil
        connections[key] = nil
        connectedPorts[key] = nil
        connectedAndroidSerials[key] = nil
        engines[key] = nil
        udids[key] = nil
        versionSkew[key] = nil
        lastSnapshots[key] = nil
        refGenerations[key] = nil
        launchedBundleIDs[key] = nil
        systemAlertProbePending.remove(key)
        uiFrameworkHints[key] = nil
        lastScreenshots[key] = nil
        rememberedSnapshotFilters[key] = nil
        sheetRescueFutile[key] = nil
        pendingWarnings[key] = nil
    }

    /// 名指しする上限本数(2026-08-12): 実測で17本が1行に並び、読み手が要るのは
    /// 「今この端末で使えるポート」だけだった。残りは件数へ畳む(runningBridgesSummary)
    static let connectionLostShownCap = 3

    static func connectionLostMessage(connection: String, running: [BridgeDiscovery.Found],
                                      sameDevice: String? = nil) -> String {
        let now = running.isEmpty
            ? "no iOS bridge is running now"
            : "running bridges now: \(Self.runningBridgesSummary(running, sameDevice: sameDevice))"
        return "\nThe XCUITest runner behind \(connection) exited — a second runner on the same"
            + " simulator kicks out the first, and the app under test crashing takes an in-app"
            + " bridge with it. \(now). Start one with `fleetest bridge up`; the session does not"
            + " survive, so ft_launch your app again."
    }

    /// **同じ端末を先に、残りは件数へ畳む**(純粋関数)。`sameDevice` が分かるとき(死んだ接続の
    /// udid をカタログへ引き直せたとき)はそれを優先して並べる —— `connection`(port/udid)と
    /// `Found`(端末名)は互いに引けないことが多いので、分からないときは並び替えず先頭
    /// `connectionLostShownCap` 本だけを名指しする(嘘のグルーピングは作らない。
    /// 「on other devices」も sameDevice が分かっているときだけ言う)
    static func runningBridgesSummary(_ running: [BridgeDiscovery.Found],
                                      sameDevice: String?) -> String {
        let sorted = running.sorted { $0.port < $1.port }
        let ordered: [BridgeDiscovery.Found]
        if let sameDevice {
            ordered = sorted.filter { $0.device == sameDevice } + sorted.filter { $0.device != sameDevice }
        } else {
            ordered = sorted
        }
        let shown = ordered.prefix(connectionLostShownCap)
        let remaining = ordered.count - shown.count
        let suffix = remaining <= 0 ? ""
            : sameDevice != nil ? " (+\(remaining) more on other devices)" : " (+\(remaining) more)"
        return shown.map(\.label).joined(separator: ", ") + suffix
    }
}
