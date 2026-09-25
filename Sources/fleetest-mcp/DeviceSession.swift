// engineKey ごとのセッション状態(1台ぶんの記憶)。**保存先はこの型1つだけ**。
// MCPServer の `drivers` / `lastSnapshots` 等は `sessions` の1欄を見る窓(`SessionMap` / `SessionFlags`)で、
// それ自体は何も持たない。**engineKey ごとの記憶を足すときはここへ欄を足す** ——
// 並列の `[String: …]` / `Set<String>` を MCPServer に戻すと、`forgetDeviceState` の消し忘れが
// 再び起き得る(束ねる前に `backgroundedByNavigate` / `webPageCeilingLatched` が実際に漏れていた)。
// `DeviceStateInvalidationTests` が並列宣言の再混入を走査で落とす。

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

struct DeviceSession {
    var driver: AppDriver?
    /// 「実際に主となったエンジン」。iosEngineHint がこれで助言を出し分ける
    /// (引数からは決まらない: profile 無しでも in-app を掴めば hybrid)
    var engine: String?
    /// **直前にエージェントへ返した木**。ref を撃つ直前に撮り直して同じ要素を引き直すための起点
    /// (RefGuard 参照)。**ref はスナップショットごとに振り直される**ので、番号ではなく要素の同一性で照合する
    var lastSnapshot: SnapshotResponse?
    /// **ref の世代管理**。ブリッジは撮るたびに ref を振り直すので、
    /// 「1つ前の木」しか起点にしない `lastSnapshot` だけでは、それより前の snapshot の ref を
    /// 撃たれたときに「たまたま同じ番号を持つ別要素」へ黙って当たる(実害: ft_scroll_to の後に
    /// 旧 ref [42](戻るボタン)を叩いたら新しい木の [42](静的テキスト「料金:」)に当たった)。
    /// MCP 層で ref にオフセット(`base`)を掛け、セッション内で全世代の ref を一意にする ——
    /// ブリッジには一切触らない。古い順に並び、**直近5世代だけ**保持する(adoptSnapshot 参照)。
    /// `actionCount` は各世代を採った時点の `sessionActionCount`(出自判定用)
    var refGenerations: [(base: Int, snapshot: SnapshotResponse, actionCount: Int)]?
    /// このセッションが撃った操作(tap/type/swipe/… — `recordAction` を通った回数)。
    /// **「このセッションは変えていない」と言ってよいかの唯一の判定材料**:
    /// `screenChangedUnderRefNote` は木の変化を「アプリ自身・他プロセス・人」のせいだと名指しするが、
    /// ref を採った世代からこの回数が増えていれば、変化はこのセッション自身の直前の操作で
    /// 説明がつく可能性が高く、外部要因のせいにしてはいけない
    var sessionActionCount: Int?
    /// **直前の `ft_tap` が叩いた要素**。ref なし `ft_type` が「叩いた欄へ焦点が
    /// 立たなかった」形を救うための材料(DSL の `StepExecutor.lastTapTarget` と同じ役)。
    /// tap / type 以外の操作(`recordInteraction`)で消える —— 間に別の操作を挟んだ type は
    /// 「叩いた欄へ入れる」意図ではない
    var lastTapTarget: ElementInfo?
    /// 座標の操作が範囲判定に使う画面の大きさ。**直近の木が無いときの控え**
    /// (`coordinateScreen`)—— 生読みで採り、世代(`lastSnapshot` / `refGenerations`)は作らない。
    /// 作ると settle-lite の「操作前の木」がこの読みになり、呼び手が撮っていない木を基準に待つ
    var knownScreen: FTRect?
    /// scroll_to の空打ちゲート用 uiFramework。**成功だけ**記憶する —
    /// 失敗(nil)を覚えると、suspend 中の1回のタイムアウトで判定がセッション全体に固定される
    var uiFrameworkHint: AppUIFramework?
    /// 実機で uiFramework が不明のまま探索を撃った(次の応答で1回だけ言う。
    /// 不明のとき空打ちは撃たれないので、Compose / Flutter なら吸われた形が赤に出る)
    var uiFrameworkUnknownPending = false
    /// 特定できたシミュレータの udid。xcuitest のマーカー判定に使う。
    /// 外側の nil = 未解決・内側の nil = 解決したが udid を持たない
    var udid: String??
    /// **最後に ft_launch した bundleID**。
    ///
    /// **Android のブリッジは session を前面ウィンドウから採る**(`SnapshotBuilder` の
    /// `root.getPackageName()`)。つまり back でアプリを出ると session がその場で別アプリに
    /// 差し替わり、`backgroundedSessionNote`(session が前面か)は**構造上まったく発火しない**。
    /// E2E の 4 SUT は `#id`・ラベルが共通契約なので、木を見ても入れ替わりに気付けない
    /// (2026-08-06 の探索で決定的に再現: `ft_launch com.ftester.e2e.android` → `back` 1回で
    /// 以後の snapshot が `com.ftester.e2e.flutter` の木になった)。
    /// **ホスト側で「起動したアプリ」を覚えて突き合わせる**のが唯一の検知経路。
    var launchedBundleID: String?
    /// `launchedBundleID` と対で、そのアプリを起動した**時刻**。
    /// Android のクラッシュ帰属(`androidProcessEvidenceForSwitch`)が
    /// 「直近の launch 以降」に絞るための起点 —— 無いと、数分〜数時間前の別プロセスの
    /// クラッシュ(adb の crash バッファは時間で絞らない限りずっと残る)を今回の launch の
    /// せいと誤って引用する
    var launchTimestamp: Date?
    /// **ツール自身がこのアプリを止めた**(ft_clear_app_data の通常経路・ft_install の
    /// 上書きインストール)ことの記録(止めた操作名。例 "ft_clear_app_data")。
    /// 値は `launchedBundleID` に対する申告 —— 別のアプリが起動されれば ft_launch が
    /// 消すので、古い記録が別アプリへ誤って付くことはない。
    /// `switchedAppNote` が「プロセスが無い = クラッシュの疑い」と誤診しないための材料
    /// (§19.3 M2: 明示的に止めた直後の snapshot が「crashed かも」と言っていた)。
    /// **ft_launch で消える**(再起動すれば以後の不在は別の原因になり得るため)
    var toolStoppedBundleID: String?
    /// **最後に ft_install した packagePath**。
    /// **実機の ft_clear_app_data が使う** —— devicectl には clearAppData の同等手段が無く
    /// (BridgeClient.clearAppData の 501)、代わりに uninstall+install で再現するのに要る
    var installedPackagePath: String?
    /// **launch 系ツール(ft_launch/ft_open_url/ft_clear_app_data/ft_install)の直後**、次の
    /// ft_snapshot で一度だけ `GET /systemalert` を確かめるための予約。
    /// DSL 側の `StepExecutor.systemAlertProbePending`(FTRuntime.swift の `noteAppLaunched`)と
    /// 同じ設計 —— launch 直後は SpringBoard の許可アラートが出やすいが、毎 snapshot 払うと
    /// 高頻度な MCP のポーリングで往復が倍になる。**springboard 自身への ft_launch では立てない**
    /// (そちらは意図してアラートを読みに行く経路なので、覆いではなく本来の画面)。
    /// snapshotBody が読んで消費(先に消してから probe)し、forgetDeviceState / ft_terminate で捨てる
    var systemAlertProbePending = false
    /// **このセッションが `ft_navigate home` / `appSwitcher` でアプリを背面へ送ったまま**か。
    /// 次の ft_launch で消す。
    ///
    /// なぜ「聞く」だけでは足りないか: `backgroundedSessionNote(_:driver:)` は `/appstate` へ
    /// 聞くが、**実機 iPhone 13 の実測でその照会が前面と答えた**(ホーム画面が出ていて、
    /// スクリーンショットでも確認済み)。木も session もアプリのままなので、ツールが送った
    /// 事実だけが唯一の確かな材料になる。**プラットフォームの答えに上書きさせない**
    var backgroundedByNavigate = false
    /// ft_screenshot の鮮度判定用。**静止画面の2連続 ft_screenshot は PNG が
    /// バイト単位で同一**(2026-08-10 実測: Android 83,028B×2 / iOS 95,076B×2)—— これが成り立つから
    /// 「木は変わったのに絵が前回と同一 = 古いフレームを返し続けている」と言える(treeFingerprint の
    /// 前後比較単独では拾えなかった動機の事象: 木は新しいのに絵だけ古い)
    var lastScreenshot: StaleFrameDetector.Record?
    /// ft_snapshot で**明示された** interactiveOnly/expandBulk。呼ばれるたびに
    /// 丸ごと置き換える(省略されたキーは記憶から消える)。snapshotAfterBody が、呼び出し側の
    /// args に無いキーだけこれで補う — 明示した値が常に優先(snapshotAfterBody 参照)
    var rememberedSnapshotFilters: [String: Bool]?
    /// **切り詰められた web ページを見たデバイス**。以後の読みは最初から要素上限の
    /// 天井で撮る(`needsWebPageCeiling`)。2枚払うのはラッチした1回だけ ——
    /// 毎回「撮る→切り詰めを見て撮り直す」だと、waitFor のポーリングで読みが倍になる
    var webPageCeilingLatched = false
    /// **シート展開救済が効かないと分かった画面**(木の指紋の集合。
    /// `sheetRescueKey` 参照)。同じ画面での2回目以降の ft_scroll_to は救済を撃たずに即返す
    var sheetRescueFutile: Set<String>?
    /// プロファイル解決で出た警告(未解決のデバイス名など)。**次に返す応答へ1度だけ**混ぜる。
    /// stderr だけに出していたときは MCP クライアントに一切届かなかった
    var pendingWarnings: [String]?
    /// ref を撃つ直前の覆い探針(`screenNotRepresentedWarning` = 覆う面とヒットテスト。
    /// `/systemalert` は含まない = 毎回聞く)を木の指紋ごとに覚える。**健全性の上限**: 木がバイト同一のまま
    /// 覆う面が出た/消えた画面(静止画面へ出た Control Center 等)は、次に木が変わるまで
    /// 再確認しない —— 見逃しはそこまでに限られる(verifiedRef 参照)
    var lastScreenProbe: (fingerprint: Int, warning: String)?
    /// 接続先の宛先(ft_status が見せる)。**#2/#5 の取り違えは「今どこに繋がっているか」が
    /// 見えないまま起きる** —— 既定 8123 が死んでいても、はぐれエミュレータを掴んでいても、
    /// 応答だけ見ると正常に見える
    var connection: String?
    /// 掴んでいる iOS ブリッジのポート。**`connection` の文字列から読み解かない**
    /// —— 表示用の文と機械判定を同じ文字列に相乗りさせると、表記を整えるたびに判定が壊れる。
    /// タイムアウト時にそのポートがまだ生きているかを確かめる `connectionLostHint` が使う
    var connectedPort: UInt16?
    /// hybrid(in-app + XCUITest)キャッシュ命中の XCUITest フォールバックポート。
    /// **`connectedPort` とは別枠**(あちらは主(in-app)のポート): `HybridFallbackDriver` の
    /// fallback は home/drag/座標 press/gesture 等をこちらへ回すので、建て直しで別デバイスへ
    /// 移っていないかは主の udid だけでは検知できない(maintainer-notes §51.2。hybridFallbackDrifted 参照)
    var hybridFallbackPort: UInt16?
    /// 掴んでいる Android ブリッジの serial。iOS の `connectedPort` と同じ理由で
    /// `connection` の表示文字列からは読み解かない —— 直接指定は "serial <serial>"、profile
    /// 経由は "<device name> serial <serial>" と経路ごとに書式が違い、文字列切り出しに頼ると
    /// profile 経由だけ判定から漏れる(2026-08-14 に実際に踏んだ)
    var connectedAndroidSerial: String?
    /// **物理 Android を起こす処理(`AndroidPhysicalDevice.prepareForRun`)を済ませた**か。
    /// run 経路(`ProfileWorkerFactory.preparePhysicalAndroidDevices`)は run の
    /// 開始前に1回だけ呼ぶので、MCP もそれと同じ粒度(このセッションでその機へ初めて触れたとき
    /// 1回)にする —— 毎ツール呼び出しに払うと adb 往復が積み上がる。`driver(_:)` が管理する
    var preparedPhysicalAndroid = false
    /// **このセッションで xcuitest ブリッジの自動建て直し(bridgeConnectionRefused からの復帰)を
    /// 一度試して失敗した**か。建て直しの成否に関わらず次にまた死んだら再挑戦してよいので、
    /// 成功時は立てない(失敗のときだけ = 環境そのものが壊れている台へ分単位のビルドを
    /// 撃ち続けない。MCPServer+BridgeRecovery.swift 参照)
    var bridgeRecoveryFailed = false
    /// 版ズレの内容。ft_status が「失敗するが理由を返す」ために覚えておく
    var versionSkew: String?
}

/// `sessions` の1欄を「engineKey → 値」の辞書として見る窓。書き込みは `sessions` へ直接届く
/// (`nonmutating set`。窓自体は何も持たないので、返された窓を保存しても古くならない)
struct SessionMap<Value> {
    let server: MCPServer
    let path: WritableKeyPath<DeviceSession, Value?>

    subscript(key: String) -> Value? {
        get { server.sessions[key]?[keyPath: path] }
        nonmutating set {
            // 消す書き込みで空のセッションを作らない
            if newValue == nil, server.sessions[key] == nil { return }
            server.sessions[key, default: DeviceSession()][keyPath: path] = newValue
        }
    }

    subscript(key: String, default defaultValue: @autoclosure () -> Value) -> Value {
        get { self[key] ?? defaultValue() }
        nonmutating set { self[key] = newValue }
    }

    var values: [Value] { server.sessions.values.compactMap { $0[keyPath: path] } }

    func first(where predicate: ((key: String, value: Value)) throws -> Bool) rethrows
        -> (key: String, value: Value)? {
        for (key, session) in server.sessions {
            guard let value = session[keyPath: path] else { continue }
            if try predicate((key, value)) { return (key, value) }
        }
        return nil
    }

    @discardableResult
    func removeValue(forKey key: String) -> Value? {
        let old = self[key]
        self[key] = nil
        return old
    }
}

/// `sessions` の Bool 欄を「立っている engineKey の集合」として見る窓(`Set<String>` と同じ呼び方)
struct SessionFlags {
    let server: MCPServer
    let path: WritableKeyPath<DeviceSession, Bool>

    func contains(_ key: String) -> Bool { server.sessions[key]?[keyPath: path] ?? false }

    @discardableResult
    func insert(_ key: String) -> (inserted: Bool, memberAfterInsert: String) {
        let already = contains(key)
        server.sessions[key, default: DeviceSession()][keyPath: path] = true
        return (!already, key)
    }

    @discardableResult
    func remove(_ key: String) -> String? {
        guard contains(key) else { return nil }
        server.sessions[key]?[keyPath: path] = false
        return key
    }

    var isEmpty: Bool { !server.sessions.values.contains { $0[keyPath: path] } }
}
