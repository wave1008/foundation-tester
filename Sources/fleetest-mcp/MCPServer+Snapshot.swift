// MCPServer+Snapshot.swift
// snapshot の取得と ref 世代管理・snapshotAfter・ft_scroll_to。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// 木を撮り直す。**MCP は必ずキャッシュを捨てて撮る**(driver が対応していれば)。
    ///
    /// Android の a11y ノードはキャッシュ供給で、**Compose のスクロール後は木が古いまま固まる**
    /// (2026-08-06 に決定的再現。撮り直しても数分待っても直らない)。ブリッジ側の既定が
    /// 「WebView 内だけ refresh」なのは**シナリオ実行**の実測(全ノード refresh で
    /// snapshot +65ms・E2E-Android の sum +43%)に基づくもので、MCP はエージェントが
    /// 1手ずつ撃つ経路なので往復のほうが桁で大きく、この上乗せは見えない。
    /// **常時オンにする**(「ジェスチャの後だけ」のフラグ運用は、フラグを立て忘れたツールが
    /// 1つでもあると黙って古い木に戻る)。
    ///
    /// 取得直後に `adoptSnapshot` を通す — ブリッジ由来の native ref をセッション ref へ
    /// 振り直すのはここが唯一の入口(waitFor 経路だけ例外。呼び出し側で個別に通す)
    func freshSnapshot(_ driver: AppDriver, args: [String: Any]) async throws
        -> SnapshotResponse {
        // `maxElements` は**この1回だけ**の上限(ブリッジの `?max=`)。既定へ戻す必要は無い ——
        // ドライバ側が1回で消費する契約なので、次の呼び出しは黙って 120 に戻る
        if let requested = args["maxElements"] as? Int {
            driver.raiseElementLimitOnNextSnapshot(requested)
            return adoptSnapshot(try await driver.snapshot(bypassingCache: driver.supportsCacheBypass),
                                 args: args)
        }
        let key = Self.engineKey(args)
        // ラッチ後は**最初から**天井で撮る(2枚払うのはラッチした1回だけ。DSL の
        // `retakenAtElementLimitCeiling` と同じ設計)
        if webPageCeilingLatched.contains(key) {
            driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
        }
        let native = try await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
        guard !webPageCeilingLatched.contains(key), Self.needsWebPageCeiling(native) else {
            return adoptSnapshot(native, args: args)
        }
        webPageCeilingLatched.insert(key)
        driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
        // **捨てる木は adopt しない**: adopt は ref 世代を進めるので、読み手に渡さない木で
        // 番号を飛ばすと「さっきの ref がもう無い」を自分で増やすことになる
        let full = try await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
        return adoptSnapshot(full, args: args)
    }

    /// 出力を短くする逃げ道の案内。**効くものだけを出す**。
    ///
    /// `interactiveOnly` は「レイアウト専用の行」を隠す道具なので、**そういう行が1つも無い画面では
    /// 1バイトも減らない** —— 実測(Yahoo 天気トップ)で 4,028B → 4,028B。要素がほぼ全部 `link` の
    /// web ページはこの形になる。効かない逃げ道を出すのは逃げ道が無いことより悪い
    /// (読み手はそれを試して1往復を捨てる)ので、消える行数を数えてから勧める。
    /// `maxElements` は常に効く(自分で上限を決め直せる)ので無条件
    static func shorteningAdvice(_ snapshot: SnapshotResponse,
                                 cache: SnapshotAnnotationCache) -> String {
        let hidden = SnapshotRenderer.hiddenByInteractiveOnlyCount(
            snapshot, flagging: cache.ghostFlags(snapshot))
        let interactive = hidden > 0
            ? " Pass interactiveOnly: true to drop \(hidden) layout-only line(s), or" : ""
        return interactive + " pass maxElements to set your own limit."
    }

    /// 待ちのポーリングが毎回かける要素上限(`Self.waitFor` の `elementLimit`)。
    /// **明示指定 > ラッチ > 既定(nil)** —— `freshSnapshot` の優先順と同じにする
    func pollElementLimit(_ args: [String: Any]) -> Int? {
        if let requested = args["maxElements"] as? Int { return requested }
        return webPageCeilingLatched.contains(Self.engineKey(args))
            ? BridgeAPI.maxSnapshotElementsCeiling : nil
    }

    /// **切り詰められた web ページなら、言われる前に天井で撮り直す**
    /// (1セッションで 89 件と 72 件を落とされた実績がある)。
    ///
    /// DSL には既に同じ撮り直し(`StepExecutor.retakenAtElementLimitCeiling`)がある一方、
    /// **MCP は別経路なので届いていなかった** —— 注記で「maxElements を上げろ」と案内するだけで、
    /// 読み手は必ず1往復を払い、注記を見落とせば**実在する行を存在しないものとして扱う**。
    ///
    /// **native の密な画面には広げない**。web だけを対象にする根拠は間引きの規則そのもので
    /// (`BridgeAPI.maxSnapshotElementsCeiling` の doc)、web ページは広告リンク等の tier0 が
    /// 枠を埋め、捨てられるのは **tier1 = ラベル付きの本文** = 読み手が欲しい行そのものになる。
    /// native のリストは操作可能な要素が優先的に残るので、同じ被害にはならない。
    /// 既に天井で読まれた木なら撮り直しても同じ木が返るだけなので撮らない。
    ///
    /// **「web ページか」の判定は `TreeCoverage.holdsWebContent` に委ねる**(2026-08-15 に修正)。
    /// 最初の実装は `type == "webView"` だけを見ており、**Android Chrome では1件も発火しなかった**
    /// (あちらの木に webView 要素は無い)。固定コーパスに Android のブラウザが7枚あったのに
    /// 当てずに入れたのが原因で、Yahoo 天気では 81 件が脱落していた
    static func needsWebPageCeiling(_ snapshot: SnapshotResponse) -> Bool {
        snapshot.truncatedCount > 0 && !SnapshotTruncation.isAtCeiling(snapshot)
            && TreeCoverage.holdsWebContent(in: snapshot)
    }

    /// ref 同一性の比較キー。(ref, type, identifier, label) — 値/frame/focused の変化では
    /// 世代を進めない(adoptSnapshot 参照)ので、この4つだけを見る
    private struct RefIdentity: Hashable {
        let ref: Int
        let type: String
        let identifier: String?
        let label: String?
    }

    private static func identity(_ element: ElementInfo, base: Int) -> RefIdentity {
        RefIdentity(ref: element.ref - base, type: element.type,
                   identifier: element.identifier, label: element.label)
    }

    /// `element` の ref だけ差し替えたコピー(ElementInfo は struct。他フィールドは素通し)
    private static func withRef(_ element: ElementInfo, _ ref: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: element.type, identifier: element.identifier,
                   label: element.label, value: element.value, placeholder: element.placeholder,
                   enabled: element.enabled, frame: element.frame, depth: element.depth,
                   checked: element.checked, web: element.web, focused: element.focused,
                   scrollable: element.scrollable, z: element.z, range: element.range)
    }

    /// `snapshot.elements` の ref に一律 `base` を足したコピー。offscreen の ref は触らない
    /// (ブリッジは常に 0 を送るスクロールヒントで、要素解決には使われない — BridgeDTO 参照)
    private static func remapped(_ snapshot: SnapshotResponse, base: Int) -> SnapshotResponse {
        guard base != 0 else { return snapshot }
        var copy = snapshot
        copy.elements = snapshot.elements.map { withRef($0, $0.ref + base) }
        return copy
    }

    /// **ref の世代管理の本体**。ブリッジから来た native な snapshot を受け取り、セッション内で
    /// 一意な ref を持つ snapshot へ変換して返す。ブリッジは撮るたびに ref を振り直すので、
    /// 何もしないと「1つ前の木」より前の snapshot の ref を撃たれたとき、たまたま同じ番号を
    /// 持つ別要素へ黙って当たる(冒頭のコメント参照)。
    ///
    /// **同一性が変わらなければ base を使い回す**: 画面が動いていないのに ref を変えると、
    /// 撮り直すたびに番号が変わってエージェントを混乱させる。ラベルが1つでも変われば
    /// (時計等)世代は進むが、それ自体は無害 —— stale 判定は「受領時点で最新だったか」で行う
    /// (resolveSessionRef 参照)ので、無関係な世代の増加が誤警告を増やすことはない。
    /// **最初の世代は base 0**(= 従来の ref とビット単位で同じ)なので、世代が1本の間は
    /// 応答が今までと完全に一致する。
    func adoptSnapshot(_ native: SnapshotResponse, args: [String: Any]) -> SnapshotResponse {
        let key = Self.engineKey(args)
        if var generations = refGenerations[key], let last = generations.last {
            let nativeIdentity = Set(native.elements.map { Self.identity($0, base: 0) })
            let lastIdentity = Set(last.snapshot.elements.map { Self.identity($0, base: last.base) })
            // **アプリが同じであることも要求する**(2026-08-13 のレビュー指摘)。`identity` は
            // frame を見ないので、**兄弟アプリの同じ画面は「同じ木」に見える**。ここで
            // 使い回すと世代が**新しいアプリの sessionBundleID で上書き**され、
            // `refFromAnotherAppMessage` の比較が B vs B になって**2回目の試行で素通り**する
            // (1回目は断るのに、同じ呼び出しをもう一度撃つと通る = 最悪の形)
            if nativeIdentity == lastIdentity,
               last.snapshot.sessionBundleID == native.sessionBundleID {
                // 同じ木 — base を使い回し、最新世代の内容だけ最新化する(frame/value/focused 等)
                let remapped = Self.remapped(native, base: last.base)
                generations[generations.count - 1] = (base: last.base, snapshot: remapped)
                refGenerations[key] = generations
                lastSnapshots[key] = remapped
                return remapped
            }
        }
        let base = nextRefBase
        let remapped = Self.remapped(native, base: base)
        var generations = refGenerations[key] ?? []
        generations.append((base: base, snapshot: remapped))
        if generations.count > Self.maxRefGenerations {
            generations.removeFirst(generations.count - Self.maxRefGenerations)
        }
        refGenerations[key] = generations
        let maxNativeRef = native.elements.map(\.ref).max() ?? -1
        // **セッション共通の採番**(engineKey ごとではない。宣言のコメント参照)
        nextRefBase = base + maxNativeRef + 1
        lastSnapshots[key] = remapped
        return remapped
    }

    /// セッション ref から要素を引く。世代を新しい順に探し、最初に見つかった世代の要素を返す。
    /// `isStale` = 最新世代以外で見つかった(= 撮り直した後にもっと新しい木が出ている)。
    ///
    /// **stale 判定はこの呼び出し時点の最新世代とだけ比べる**: 呼び手(verifiedRef 等)が
    /// この後で自分で撮り直して世代を進めても、それはエージェントが ref を送った**後**の話なので
    /// stale 扱いにしない。ここを先に評価してから撮り直すという順序を崩すと、時計のラベル変化
    /// だけで世代が進むたびに全タップへ偽の「older snapshot」警告が付く
    func resolveSessionRef(_ ref: Int, args: [String: Any])
        -> (element: ElementInfo, isStale: Bool)? {
        guard let generations = refGenerations[Self.engineKey(args)] else { return nil }
        for (offset, generation) in generations.enumerated().reversed() {
            if let element = generation.snapshot.elements.first(where: { $0.ref == ref }) {
                return (element, offset != generations.count - 1)
            }
        }
        return nil
    }

    /// **ref を採った木と、今の木が同じアプリか**(2026-08-13・「アプリ切替」の監査で実機再現)。
    ///
    /// ref の世代は engineKey(= 機)ごとで、**アプリでは区切っていない**。同じ機で別アプリを
    /// 起動すると、前のアプリで採った ref が次のアプリの木に対して再照合され、
    /// **`#id` が同じなら黙って当たる**。E2E の 5 SUT は `#id`・ラベルが共通契約なので
    /// これは机上の話ではない —— 実測(iOS・同一機)で `com.ftester.e2e` の `#nav_selector`
    /// (ref 54)を採ってから `com.ftester.e2e.ios` を launch して撃つと `tap [54] done` で
    /// **別アプリの同名要素を叩き**、しかも注記は
    /// 「1px 動いた・周囲のレイアウトが変わった」と**自信を持って誤説明**した。
    /// `switchedAppNote` は「起動したアプリ = 前面」を見るので、明示 launch した後は発火しない
    /// —— 見ていないのは**ref の出自**のほうだった。
    ///
    /// **どちらかが不明なら何もしない**(旧ブリッジは sessionBundleID を返さない。
    /// 「分からない」を「変わった」と読むと毎回拒否になる)
    static func refFromAnotherAppMessage(ref: Int, takenFrom: SnapshotResponse?,
                                         fresh: SnapshotResponse) -> String? {
        guard let taken = takenFrom?.sessionBundleID, let now = fresh.sessionBundleID,
              taken != now else { return nil }
        return "[\(ref)] was taken from \(taken) but the app in front is now \(now)"
            + " — refusing, because refs are per-device and not per-app: sibling apps can expose"
            + " the same ids and labels, so this would silently hit a different app's element."
            + " Take a fresh ft_snapshot and use the new refs."
    }

    /// **ref を採ったときの木と、撃つ直前の木が違う**ことの警告(2026-08-15・Simulator で再現)。
    ///
    /// なぜ要るか: 既存の警告はどれも**要素の見え方**を見ている(gone / ghost / moved /
    /// ラベル変化 / 遮蔽 / 別アプリ)ので、**同じ id・同じラベル・同じ frame の別インスタンス**を
    /// 掴んだときに1つも当たらない。実測 —— E2EAppCMP のセレクタ画面で `#btn_back`(ref 350)を
    /// 採り、**ツールの外から** `simctl openurl` でライフサイクル画面へ進めてから撃つと、
    /// `tap [350] done.` だけを返してライフサイクル画面の `#btn_back`(同じ frame・同じ「戻る」)を
    /// 叩く。`isStale` も当たらない —— 間に snapshot を挟んでいないので ref は最新世代のままだから。
    ///
    /// **しきい値を持たない**: 「木の類似度が閾値以下なら別画面」は固定コーパスで棄却済み
    /// (同じ画面の別状態 0.33 と別画面 0.30/0.35 が重なり、別画面で 0.92 のペアもある)。
    /// `adoptSnapshot` は同一性が変わらなければ世代を進めない = 同一性の一致がそのまま
    /// 「変わっていない」の表明なので、**厳密比較でよい**。
    ///
    /// **比較キーに ref と frame を入れない**: ref は世代でずれ、frame はスクロールで動くが、
    /// どちらも「画面が別物になった」ことを意味しない。
    ///
    /// **断定しない**: 木からは「別の画面か」を決められない(できないことは上の棄却が示している)。
    /// 事実(木が違う・このセッションの操作では変えていない)だけを述べて撮り直しを勧める。
    /// `isStale` のときは黙る —— あちらの注記が同じことを既に言っており、二重になる
    static func screenChangedUnderRefNote(ref: Int, takenFrom: SnapshotResponse?,
                                          fresh: SnapshotResponse, isStale: Bool,
                                          matched: ElementInfo) -> String {
        guard !isStale, let taken = takenFrom,
              Self.treeIdentity(taken) != Self.treeIdentity(fresh) else { return "" }
        return " note: [\(ref)] came from a snapshot whose tree no longer matches the current one,"
            + " and nothing this session did changed it — the app itself, another process or a"
            + " person moved the screen on. It still matched \(RefGuard.describe(matched)), but that"
            + " can be the same-looking element of a different screen. Take a fresh ft_snapshot."
    }

    /// 木の同一性(型 + identifier + ラベルの集合)。`identity` と違い **ref を含めない** ——
    /// あちらは世代の据え置き判定用で、こちらは**別の木どうし**を比べる
    private static func treeIdentity(_ snapshot: SnapshotResponse) -> Set<String> {
        Set(snapshot.elements.map {
            "\($0.type)\u{1}\($0.identifier ?? "")\u{1}\($0.label ?? "")"
        })
    }

    /// この ref を持っている**別の** engineKey(= 別の宛先、または同じ機の別の指し方)。
    /// 拒否するときに出自を名指しするために使う —— 「不明な番号」とだけ言うと、
    /// 呼び手は撃ち間違いだと読んで同じ番号を別の宛先へ撃ち直す
    func otherKeyHolding(_ ref: Int, args: [String: Any]) -> String? {
        let current = Self.engineKey(args)
        return refGenerations.first { key, generations in
            key != current
                && generations.contains { $0.snapshot.elements.contains { $0.ref == ref } }
        }?.key
    }

    /// 別の宛先(または別の指し方)で採った ref を撃たれたときの拒否文。
    /// **engineKey をそのまま出す** —— 呼び手が実際に書いた引数の形なので照合できる
    static func refFromAnotherTargetMessage(ref: Int, takenUnder: String,
                                            firedAt: String) -> String {
        "[\(ref)] was taken under a different target (\(takenUnder)), but this call addressed"
            + " \(firedAt) — refusing, because ref numbers are scoped to the target they were"
            + " taken from. Forwarding it would let that bridge resolve the number in its own"
            + " numbering and silently operate a different element."
            + " Take a fresh ft_snapshot for this target and use the new refs."
    }

    /// `ref` を含む世代の snapshot 全体(movedTogether の兄弟比較に使う「同じ世代の他の要素」用。
    /// resolveSessionRef と同じ探索だが、要素1件ではなく世代の全体が要る)
    func generationSnapshot(containing ref: Int, args: [String: Any]) -> SnapshotResponse? {
        refGenerations[Self.engineKey(args)]?.reversed()
            .first { $0.snapshot.elements.contains { $0.ref == ref } }?.snapshot
    }

    /// セッション ref → native ref(ブリッジへ渡す番号)。**最新世代の base を引くことでしか
    /// 正しく戻せない** —— 渡してよいのは verifiedRef/verifiedElement が返した「撮り直した後の」
    /// ref だけという規約(古い世代の ref を渡すと、その世代の base を引いても、ブリッジは
    /// とうにその番号を再利用しているので無効)。世代が無ければ素通し(従来どおり)
    func nativeRef(_ sessionRef: Int, args: [String: Any]) -> Int {
        guard let last = refGenerations[Self.engineKey(args)]?.last else { return sessionRef }
        return sessionRef - last.base
    }

    /// スナップショット本文(注記一式 + 木)。ft_snapshot と `snapshotAfter` が共有する ——
    /// **2つ目の組み立てを作らない**(注記を1つ足したときに片方だけ出る事故を防ぐ)。
    /// `extraNote` は ft_snapshot の waitFor 用(すり替わりの直後・他の注記より前に置く)。
    /// `cache` は計測用の注入口(既定 nil = 呼ぶたびに新しく作る、production の全経路がこちら)。
    /// **snapshot を跨いで渡さない**——SnapshotAnnotationCache のコメント参照
    func snapshotBody(_ snapshot: SnapshotResponse, driver: AppDriver,
                              args: [String: Any], extraNote: String = "",
                              cache: SnapshotAnnotationCache? = nil) async -> String {
        let cache = cache ?? SnapshotAnnotationCache()
        // **背面のアプリのツリーを「今の画面」として返さない**: XCUITest の snapshot は
        // セッションのアプリに閉じているので、**別のアプリが前面に来ても同じ木を返し続ける**。
        // 実測(2026-08-05・シミュレータで確定。症状の初出は iPhone 実機):
        // ステータスバーの「◀ 元のアプリへ」を踏んだタップで前面が別アプリに替わったのに、
        // snapshot は元アプリの画面を返し、エージェントからは「タップが効かない」に見えた
        var backgroundNote = await Self.backgroundedSessionNote(snapshot, driver: driver)
        // **照会が前面と答えても、こちらが送った事実は消えない**(実機で実際にそうなった。
        // `backgroundedByNavigate` の doc)。照会が既に言えているときは重ねない
        if backgroundNote.isEmpty, backgroundedByNavigate.contains(Self.engineKey(args)) {
            backgroundNote = Self.sentToBackgroundNote(snapshot.sessionBundleID)
        }
        // **すり替わりを先頭に置く**: これが起きているとき、以下の一覧は丸ごと別アプリのもので、
        // ghost 注記も scrollFrame 候補も読む意味が無い
        let switchedNote = Self.switchedAppNote(
            launched: launchedBundleIDs[Self.engineKey(args)], snapshot: snapshot)
        // **launch 系ツールの直後だけ・一度だけ** system alert を確かめる
        // (systemAlertProbePending 参照。DSL の noteAppLaunched と同じ設計)。
        // **先に鍵を消してから probe する** —— この呼び出し自体が非同期で待つため、
        // 消し忘れると再入(snapshotAfter 経由の二重呼び出し等)で二重に払う
        var alertNote = ""
        let alertKey = Self.engineKey(args)
        if systemAlertProbePending.contains(alertKey) {
            systemAlertProbePending.remove(alertKey)
            let alert = await Self.systemAlertNote(driver: driver)
            if !alert.isEmpty { alertNote = alert + "\n" }
        }
        // **ghostNote と render で畳みの有無を揃える**: 片方だけ expandBulk を無視すると、
        // 注記は「畳んだ」と言うのに木は個別列挙、という食い違いになる
        let collapsingBulk = args["expandBulk"] as? Bool != true
        // **木だけから決まる注記は NoteCatalog が唯一の定義元**(並び順・短縮・A/B の黙らせも
        // あちら)。ここへ直に `Self.xxxNote(...)` を足さないこと —— 足すと発火が測れなくなり、
        // NoteCoverageTests のソース走査が落ちる
        // **勝手に上限を上げたことは名乗る**(黙って出力量が3倍になると、読み手は
        // 自分の指定が効いていないと読む)。初回だけ満額 —— 以後は同じ device で常時なので
        let ceilingNote = webPageCeilingLatched.contains(Self.engineKey(args))
            ? once("webPageCeilingRetake",
                   full: "note: this device showed a truncated web page, so snapshots for it are"
                       + " now taken at the \(BridgeAPI.maxSnapshotElementsCeiling)-element ceiling"
                       + " instead of the \(BridgeAPI.maxSnapshotElements) default — on a web page"
                       + " the dropped elements are the labelled body text, and they are gone from"
                       + " the tree rather than off screen (scrolling never brings them back)."
                       + Self.shorteningAdvice(snapshot, cache: cache) + "\n",
                   short: "")
            : ""
        return switchedNote + alertNote + ceilingNote + extraNote + backgroundNote
            + catalogNotes(NoteCatalog.Input(snapshot: snapshot, collapsingBulk: collapsingBulk,
                                             cache: cache), context: .snapshot)
            + SnapshotRenderer.render(snapshot, flagging: cache.ghostFlags(snapshot),
                                      collapsingBulk: collapsingBulk,
                                      interactiveOnly: args["interactiveOnly"] as? Bool == true,
                                      unit: Self.coordinateUnit(driver))
    }

    /// 木に添える座標の単位。**ドライバの実体で決める**(args の platform は省略されうる)。
    /// 判定は純粋関数に分けてある —— `AndroidDriver` の生成には adb の実在が要るので、
    /// これを分けないと単位の規則をテストするだけでホストの都合に縛られる
    static func coordinateUnit(_ driver: AppDriver) -> String {
        coordinateUnit(isAndroid: driver is AndroidDriver)
    }

    static func coordinateUnit(isAndroid: Bool) -> String { isAndroid ? "px" : "pt" }

    /// `snapshotAfter` が読む木は基本的に整定を待たないという注意を初回だけ満額で出す
    /// (2026-08-10。settle-lite 追加後も「基本的に」待たない: 直後の木が操作前と見分けが
    /// 付かないときだけ、snapshotAfterBody が1回だけ短い待ちを挟んで撮り直す)。
    /// 実測: ft_type の直後は候補リストがまだネットワーク待ちで、waitFor 付きの ft_snapshot なら
    /// 出るものが「候補なし」に見えた
    /// **満額を短くした**。実運用の記録で**最もバイトを食っている注記**だった
    /// (20 run で 7,180 B = 359 B を毎 run 満額で。Bench/measurements.md)。
    /// 落としたのは「不変に見えたら1回だけ待って撮り直した(上の注記を見よ)」の説明 ——
    /// **それが実際に起きた回には settle-lite の注記そのものが出る**ので二重だった。
    /// 残したのは行動に要る2つ:「操作直後の木である」と「waitFor で確かめてから無いと言え」
    private func immediateReadNote() -> String {
        once("snapshotAfterImmediateNote",
            full: "note: this tree was read immediately after the action — a dynamic list"
                + " (search suggestions, network results) may not have populated yet."
                + " If something you expect is missing, confirm with ft_snapshot waitFor"
                + " before concluding it is absent.\n",
            short: "(immediate read — see the first snapshotAfter note)\n")
    }

    /// 直後の木が操作前と区別できないときだけ挟む、1回きりの短い再読(settle-lite。2026-08-10)。
    /// **value と frame を比較に含めるのが要点**: ft_type 直後は value が変わるので「変化あり」に
    /// なり無駄な待ちが入らない/ スクロールを伴うタップは frame が動くので同じ理由で入らない。
    /// **push 遷移が主目的**: 操作直後の木が古いまま返り、snapshotAfter が空振りして
    /// 別途 ft_snapshot を要求される実測から。
    /// **FTCore.StaleFrameDetector へ寄せない**: あちらの指紋は ref/type/identifier/
    /// label/frame までで、value/checked の変化には反応しない(あちらはスクリーンショットの
    /// 鮮度判定用で、ここが要る「入力しただけの変化」を感知できない)
    /// **同一性判定はこの1本だけ**(ft_batch も跨いで呼ぶ。2つ目を書かない)
    /// **truncatedCount も見る**(2026-08-13 監査): `elements` はブリッジ側で既に
    /// maxSnapshotElements(既定120)へ切り詰め済みなので、変化が切り詰められた側だけに
    /// 起きると `elements` は同一のまま検知できない(実測: iOS Safari の横スクロール表で
    /// タップ後に +113 件がすべて cutoff の下に並び、生存 120 行はバイト同一だった)。
    /// **bulkExemptCount は見ない**: bulk 群(BridgeSnapshotThinning)は cap の外でも常に
    /// `elements` へ送られる(捨てられない)ので、その増減は既に `elements` の差分に現れており、
    /// 二重に見る意味が無い
    static func looksUnchanged(_ before: SnapshotResponse, _ after: SnapshotResponse) -> Bool {
        guard before.elements.count == after.elements.count,
              before.truncatedCount == after.truncatedCount else { return false }
        return zip(before.elements, after.elements).allSatisfy { a, b in
            a.ref == b.ref && a.type == b.type && a.identifier == b.identifier
                && a.label == b.label && a.value == b.value && a.checked == b.checked
                && a.frame == b.frame
        }
    }

    /// **画面のどれだけが木に一つも表れていないか**(0〜1、画面高比)。空/ほぼ空の木は
    /// 「空 == 空」で必ず `looksUnchanged` に一致するため、この比率が高いときは
    /// 「unchanged」系の注記に「そもそも公開されていないだけかもしれない」ことを言い添える
    /// (unrepresentedScreenCaveat 参照)。**算出は `unrepresentedScreenFraction`
    /// (MCPServer+Hints.swift)に委ねる**(2つ目の計算を作らない)
    static let unrepresentedScreenCaveatThreshold = 0.5

    /// `looksUnchanged` 系の verdict(waitForChange タイムアウト・settle-lite・waitFor の
    /// 「action itself may not have taken effect」・ft_batch の「still identical」)へ共通で足す
    /// 注意書き。実測(Android Chrome): 木がブラウザ chrome の19要素(後に1要素)だけのまま、
    /// ft_batch の scrollDown ×4 が画面を実際に数スクロール分動かしたのに「変化なし」と返った ——
    /// ページの中身がそもそも a11y tree に載っていなかった。
    /// **失敗にはしない**(既存の note を補足するだけ)。返り値は先頭にスペース1つを含む断片
    /// (呼び手の文へそのまま連結する。独立行にするときは呼び手側で `\n` を足す)
    static func unrepresentedScreenCaveat(_ snapshot: SnapshotResponse) -> String {
        let fraction = unrepresentedScreenFraction(snapshot)
        guard fraction >= unrepresentedScreenCaveatThreshold else { return "" }
        return " (note: \(Int((fraction * 100).rounded()))% of the screen has no element in the"
            + " tree at all, so \"unchanged\" cannot tell \"nothing moved\" from \"nothing was"
            + " published\" — use ft_screenshot to see what is actually on screen.)"
    }

    /// **中身が1つも入っていない大きなスクロール容器**の名前(無ければ nil)。
    ///
    /// `looksUnchanged` では拾えない「まだ読み込み中」の形を1つだけ足す(2026-08-12 の監査)。
    /// 実測(Google マップ・経路検索): 出発地/目的地を確定した直後の snapshotAfter は
    /// `#expandingscrollview_container` が**子ゼロ**のまま返り、経路一覧は次の ft_snapshot で
    /// 初めて出た —— 木そのものは前の画面から大きく変わっているので、既存の settle-lite
    /// (操作前と見分けが付かないときだけ待つ)は構造上まったく発火しない。
    ///
    /// **誤発火を避けるための3条件**:
    /// - `scrollable` 申告がある容器だけ(true を見つけたときだけ使ってよい。ElementInfo の宣言参照)
    /// - **画面の3割以上の高さ**を占める容器だけ(小さな横カルーセルの空は正常なことがある)
    /// - 子が**1つも無い**(preorder で depth が大きい後続要素が0件)—— 1件でも入っていれば
    ///   「描画は始まっている」ので待たない
    ///
    /// 空のリストは正当にも存在する(検索結果0件)ので、**これを根拠に throw も再試行もしない** ——
    /// 呼び手が払うのは settle-lite と同じ1回きりの短い待ちだけ
    static func emptyLoadingScroller(in snapshot: SnapshotResponse) -> ElementInfo? {
        let screenHeight = snapshot.screen.height
        guard screenHeight > 0 else { return nil }
        let elements = snapshot.elements
        for (index, element) in elements.enumerated() {
            guard element.scrollable == true,
                  element.frame.height >= screenHeight * emptyScrollerScreenRatio else { continue }
            let hasChild = elements[(index + 1)...].prefix { $0.depth > element.depth }.isEmpty == false
            if !hasChild { return element }
        }
        return nil
    }

    /// `emptyLoadingScroller` が見る容器の最小の高さ(画面比)。小さな帯(フィルタの横並び等)の
    /// 空は正常なので、**画面の主役になる大きさ**だけを読み込み中の候補にする
    static let emptyScrollerScreenRatio = 0.3

    /// waitFor は snapshotAfter の待ち方の指定であって独立の引数ではない。
    /// snapshotAfter なしで渡されたら黙って無視せず気付かせる —— **throw はしない**
    /// (操作そのものは既に実行済みなので、ここで落とすと二重操作を誘う)
    func waitForWithoutSnapshotAfterNote(_ args: [String: Any]) -> String {
        guard args["snapshotAfter"] as? Bool != true else {
            // **併用は黙って waitFor が勝つ形にしない**: 待つ理由が違う(選択子の出現 対
            // 木の変化)ので、片方が無視されたことは言う
            guard args["waitFor"] != nil, args["waitForChange"] as? Bool == true else { return "" }
            return " (note: waitForChange was ignored — waitFor was given and takes precedence)"
        }
        let given = [args["waitFor"] != nil ? "waitFor" : nil,
                     args["waitForChange"] as? Bool == true ? "waitForChange" : nil].compactMap { $0 }
        guard !given.isEmpty else { return "" }
        return " (note: \(given.joined(separator: "/")) requires snapshotAfter: true —"
            + " it was ignored)"
    }

    /// 直近の ft_snapshot の**明示指定**(`rememberedSnapshotFilters`)を、木を返す応答へ引き継ぐ。
    ///
    /// **木を返す口はすべてここを通す**(`snapshotAfter` と `ft_scroll_to`)。片方だけ継承すると
    /// 「interactiveOnly を渡した後、どのツールで読むかで出力量が変わる」になり、読み手は
    /// 自分の指定が効いていないと読む —— 実際に `ft_scroll_to` だけが継承せず、
    /// 継承しなかったことも言っていない形になっていた。
    /// **明示された値が常に優先**: args に無いキーだけ記憶で補う。補った値が true の
    /// ときだけ宣言する(false を補っても render の既定と同じなので出力は変わらない)
    func inheritingSnapshotFilters(_ args: [String: Any]) -> (args: [String: Any], note: String) {
        let key = Self.engineKey(args)
        var effective = args
        var note = ""
        for filterKey in ["interactiveOnly", "expandBulk"] {
            guard !(args[filterKey] is Bool),
                  let remembered = rememberedSnapshotFilters[key]?[filterKey] else { continue }
            effective[filterKey] = remembered
            if remembered {
                note += "(\(filterKey): true inherited from your last ft_snapshot —"
                    + " pass \(filterKey): false to override)\n"
            }
        }
        return (effective, note)
    }

    /// 操作系ツールが `snapshotAfter: true` で返す「操作の直後の画面」。
    ///
    /// **往復を半分にするためにある**: tap/type/drag は「変わったかもしれない」で終わるので、
    /// 読み手はほぼ必ず ft_snapshot を続けて撃つ。実測(2026-08-09 のマップ探索1セッション)では
    /// 46 回の呼び出しのうち 21 回が**この確認だけの snapshot** だった。
    ///
    /// **撮るのは操作の直後**。木が操作前(`lastSnapshots`)と見分けが付かないときだけ、
    /// `settleWaitSeconds` だけ待って1回だけ撮り直す(settle-lite。looksUnchanged 参照) ——
    /// 撮り直しても同一なら「変わっていないかもしれない」と言うだけで、それ以上は待たない。
    /// 操作前の木を知らない(`lastSnapshots` が無い)ときは何もしない。
    /// **失敗しても throw しない**: 操作自体は成功しているので、ここで throw すると
    /// 「タップは効いたのにエラーが返る」になり、読み手が操作を撃ち直して二重操作になる。
    /// **waitFor があれば settle-lite の代わりにそちらを使う**(両方は走らせない)
    func snapshotAfterBody(_ args: [String: Any]) async -> String {
        await snapshotAfterBodyWithStatus(args).text
    }

    /// `snapshotAfterBody` 本体。**back の無効判定(ft_navigate)が succeeded を見る**
    ///: catch した回(読みに失敗した回)は `lastSnapshots` が back 前の木のまま
    /// 残るため、`succeeded` を返さずに「今の lastSnapshots」だけを見ると back 前の木と
    /// 指紋が自明に一致し、謝罪文の横に「back は効かなかった」という偽の注記が並ぶ
    /// (2026-08-12 実測)。他の呼び出し口は text だけを使い、この差は見ない
    func snapshotAfterBodyWithStatus(_ args: [String: Any]) async -> (text: String, succeeded: Bool) {
        guard args["snapshotAfter"] as? Bool == true else { return ("", false) }
        do {
            let snapshotDriver = try await driver(args)
            let key = Self.engineKey(args)
            let beforeAction = lastSnapshots[key]

            let (effectiveArgs, inheritedNote) = inheritingSnapshotFilters(args)

            var snapshot = try await freshSnapshot(snapshotDriver, args: args)
            var settleNote = ""
            var waitNote = ""
            // **waitFor は settle-lite の代わり**(併用しない): 待つ理由が同じ(木がまだ
            // 追いついていない)なので、両方は二重に待つだけ。パターンは ft_snapshot の
            // waitFor 分岐と同じ(refetched の扱いも含め)
            if let waitFor = args["waitFor"] as? String {
                let seconds = args["timeout"] as? Double ?? Self.defaultWaitSeconds
                let waited = try await Self.waitFor(waitFor, driver: snapshotDriver,
                                                    first: snapshot, seconds: seconds,
                                                    elementLimit: pollElementLimit(args))
                snapshot = waited.refetched ? adoptSnapshot(waited.snapshot, args: args) : waited.snapshot
                waitNote = waited.found ? "waitFor \"\(waitFor)\" appeared.\n"
                    : "waitFor \"\(waitFor)\" did not appear within \(Self.secondsText(seconds))"
                        + Self.waitTimeoutRemedy
                        + " — this is the screen as it is now\(Self.truncationHint(snapshot))"
                        + (waited.partialSeenAfter.map { seenAfter in
                            " — a partial match was already on screen \(Int(seenAfter.rounded()))s"
                                + " into the wait:\(waited.partialHint) The exact form never"
                                + " appeared, so the wait ran to the deadline"
                        } ?? (Self.notationHint(waitFor, in: snapshot)
                              + Self.similarLabelsHint(waitFor, in: snapshot)))
                        + Self.waitForScrollHint(in: snapshot)
                        // **操作の効果も疑う**(2026-08-12 監査): waitFor はここでしか「操作前の木」
                        // を持たない(ft_snapshot 単独には操作前が無い)。判定は settle-lite/
                        // waitForChange と同じ looksUnchanged を再利用する(2つ目の同一性判定を書かない)
                        + (beforeAction.map { Self.looksUnchanged($0, snapshot) } == true
                           ? " the tree is also identical to the one before the action, so the"
                             + " action itself may not have taken effect."
                             + Self.unrepresentedScreenCaveat(snapshot)
                             + Self.systemDialogHint(engine: engines[Self.engineKey(args)])
                           : "") + "\n"
            } else if args["waitForChange"] as? Bool == true {
                let result = try await waitForChangeBody(beforeAction: beforeAction,
                                                         snapshot: snapshot,
                                                         driver: snapshotDriver, args: args)
                snapshot = result.snapshot
                settleNote = result.note
            } else if let beforeAction, Self.looksUnchanged(beforeAction, snapshot) {
                try await Task.sleep(nanoseconds: UInt64(max(0, settleWaitSeconds) * 1_000_000_000))
                let reread = try await freshSnapshot(snapshotDriver, args: args)
                if Self.looksUnchanged(snapshot, reread) {
                    settleNote = "note: the tree still looked unchanged after a short re-read"
                        + " wait — the action may not have changed the screen."
                        + Self.unrepresentedScreenCaveat(reread)
                        + Self.systemDialogHint(engine: engines[Self.engineKey(args)]) + "\n"
                } else {
                    settleNote = "note: the tree looked unchanged right after the action, so it"
                        + " was re-read once after a short wait — the tree below is the re-read.\n"
                }
                snapshot = reread
            } else if let empty = Self.emptyLoadingScroller(in: snapshot) {
                // **木は変わったのに中身がまだ来ていない**形(emptyLoadingScroller 参照)。
                // 待ちも回数も settle-lite と同じ = 1回きりの短い猶予しか払わない
                try await Task.sleep(nanoseconds: UInt64(max(0, settleWaitSeconds) * 1_000_000_000))
                let reread = try await freshSnapshot(snapshotDriver, args: args)
                let name = RefGuard.describe(empty)
                if Self.emptyLoadingScroller(in: reread) == nil {
                    settleNote = "note: \(name) was still empty right after the action, so the tree"
                        + " was re-read once after a short wait — the tree below is the re-read.\n"
                    snapshot = reread
                } else {
                    // **埋まらなかったら黙らない**: 正当に空(検索結果0件)のこともあるので、
                    // 断定はせず「空のまま」だとだけ言う。読み手はここで waitFor を選べる
                    settleNote = "note: \(name) is still empty after a short re-read wait — it may"
                        + " be genuinely empty, or still loading; use ft_snapshot waitFor if you"
                        + " expect content in it.\n"
                    snapshot = reread
                }
            }
            recordSnapshot(snapshot, snapshotDriver is AndroidDriver ? "android" : "ios", args)
            // waitFor 済みなら「待たずに読んだ」前提の immediateReadNote は誤解を招くので出さない
            let readNote = waitNote.isEmpty ? immediateReadNote() : ""
            let body = "\n\n" + inheritedNote + waitNote + settleNote + readNote
                + (await snapshotBody(snapshot, driver: snapshotDriver, args: effectiveArgs))
            return (body, true)
        } catch {
            let body = "\n\n(snapshotAfter could not read the screen:"
                + " \(error.localizedDescription) — the action above still went through;"
                + " take an ft_snapshot yourself)"
            return (body, false)
        }
    }

    /// `snapshotAfterBodyWithStatus` の waitForChange 分岐(waitFor の隣の抽出。2026-08-12)。
    /// **beforeAction が無ければ待たない**(比較対象が無いので「変わった」と言う材料が無い)。
    /// 戻り値の snapshot は撮り直した最新の木(呼び手はこれで自分の `snapshot` を置き換える)
    func waitForChangeBody(beforeAction: SnapshotResponse?, snapshot initial: SnapshotResponse,
                           driver: AppDriver, args: [String: Any]) async throws
        -> (snapshot: SnapshotResponse, note: String) {
        guard let beforeAction else {
            return (initial, "note: waitForChange had no earlier tree to compare with"
                + " (nothing was read on this device yet), so it did not wait.\n")
        }
        var snapshot = initial
        let seconds = args["timeout"] as? Double ?? Self.defaultWaitSeconds
        let deadline = Date().addingTimeInterval(max(0, seconds))
        var changed = !Self.looksUnchanged(beforeAction, snapshot)
        let changedOnFirstRead = changed
        while !changed, Date() < deadline {
            try await Task.sleep(for: .seconds(Self.waitPollSeconds))
            snapshot = try await freshSnapshot(driver, args: args)
            changed = !Self.looksUnchanged(beforeAction, snapshot)
        }
        guard changed else {
            return (snapshot, "note: waitForChange timed out after \(Self.secondsText(seconds))"
                + Self.waitTimeoutRemedy + " — the tree"
                + " still matches the one before the action, so the action may not"
                + " have changed the screen."
                + Self.unrepresentedScreenCaveat(snapshot) + "\n")
        }
        // **「変わった」は「終わった」ではない**: 最初に差が出た木が遷移途中のこともある
        // (2026-08-12 の実測: 検索結果がまだネットワーク待ちの「候補なし」中間状態で確定を
        // 返した)。直前の読みと一致するまで少数回だけ読み直して採り直す。timeout には縛らない
        // (settle-lite と同じく操作後の固定小コストであって、待ち時間の指定ではない)
        var churn = 0
        var stable = false
        for _ in 0..<Self.changeSettleRereads {
            try await Task.sleep(nanoseconds: UInt64(max(0, settleWaitSeconds) * 1_000_000_000))
            let reread = try await freshSnapshot(driver, args: args)
            if Self.looksUnchanged(snapshot, reread) { stable = true; break }
            snapshot = reread
            churn += 1
        }
        var note = "waitForChange: the tree differs from the one before the action.\n"
        if !stable {
            note += "note: the tree was still changing between re-reads —"
                + " it may not have settled; re-check (ft_snapshot, optionally"
                + " waitFor) before relying on it.\n"
        } else if churn > 0 {
            note += "note: it kept changing after the first difference —"
                + " the tree below is the latest read.\n"
        } else if changedOnFirstRead {
            // 安定確認は「中間状態がそれ自体しばらく静止している」場合を
            // 見抜けない —— 遷移を1度も観測していないことだけは言える
            // **「確かめろ」で終えない**: 旧文はここまで来た木が
            // 何を通っているかを言わずに確認だけ促しており、読み手は素の ft_snapshot を
            // もう1回撃っていた —— この分岐は `stable && churn == 0`、つまり
            // **撮り直して同一だった**ときにしか来ないので、同じ木がもう1枚返るだけの丸損。
            // 済んでいることを先に言い、残る唯一の疑い(静止した読み込み中)と、
            // それに効く**別の**手(waitFor)を名指しする
            note += once("waitForChangeFirstReadNote",
                full: "note: the difference was already present on the first"
                    + " read, so no transition was observed. The tree was still"
                    + " re-read until it stopped changing, so reading it again"
                    + " now returns the same thing — another ft_snapshot will not"
                    + " tell you more. What this cannot rule out is a screen that"
                    + " settles into a loading or empty state; if you are waiting"
                    + " for specific content, ask for it directly with"
                    + " ft_snapshot waitFor: <selector>.\n",
                short: "(already differed on the first read — see the earlier"
                    + " waitForChange note)\n")
        }
        return (snapshot, note)
    }

    /// ref を撃つ直前の照合。**撮り直した木から同じ要素を引き直して、その新しい ref を返す**。
    /// 引けない(消えた・ghost)なら撃たずに throw する —— 沈黙した誤操作を作らないため。
    ///
    /// 直前の木を覚えていないとき(ft_snapshot を挟まずに ref を撃たれたとき)は素通しする:
    /// 照合の起点が無いので嘘の判断をするより、ブリッジの 404 に任せるほうが正しい。
    /// **どの世代にも無い ref**(何か撮った後で、それでも一致しない番号)は素通しせず throw する
    /// —— セッション内で ref は一意なので、世代があるのに見つからないのは番号の書き間違いか、
    /// 直近5世代より前の snapshot からコピーしてきた番号のどちらか。
    ///
    /// **素通しの条件はセッション全体で見る**(2026-08-14・実機+仮想デバイス混在の監査)。
    /// 以前は「この engineKey に世代が無いか」で判定していたが、engineKey は**指し方**込み
    /// (`profile:<project>:<name>` / `direct:ios:<port>:`)なので、**同じ機を profile: で撮って
    /// port: で撃つ**だけで「世代なし」になり、番号がそのままブリッジへ渡っていた。
    /// ブリッジは自前の 1..N で解決するので**別の要素に当たって成功と報告する** ——
    /// 実機で再現: profile: で撮った木の ref は 70..93 なのに `port:8143 ref:10` が
    /// `tap [10] done` を返し、ブリッジの #10 = `#btn_input_submit` を実際に押した
    /// (`submitted=-` → `submitted=physical`)。既存の「機を跨いだ ref」テストが通っていたのは
    /// 「木が画面を代表していない」の申告由来の警告。**覆いを先に聞く**(2026-08-28 実機で実測):
    /// 通知センターが出ているときは覆いの検知と `hitTest` の**両方**が発火し、後者は
    /// 「アプリスイッチャーが開いている」という**誤った説明**を並べてしまう。
    /// 面が分かっているならそちらが正確なので、当たったほうだけを言う。
    /// 覆っているときは `hitTest` を聞かずに済むので往復も1つ減る
    static func screenNotRepresentedWarning(_ found: ElementInfo, driver: AppDriver) async -> String {
        // **名指しできるアラートを最初に聞く**: SpringBoard の許可アラートは覆い判定
        // (systemUICoveringWarning)より確度が高い名指しができる(題名・ボタンまで読める)
        let alert = await systemAlertNote(driver: driver)
        if !alert.isEmpty { return " (\(alert))" }
        let covering = await systemUICoveringWarning(found, driver: driver)
        if !covering.isEmpty { return covering }
        return await treeDoesNotMatchScreenWarning(found, driver: driver)
    }

    /// **`screenNotRepresentedWarning` を毎タップ聞き直さない**(2026-08-31)。
    /// 撃つ前の照合(`verifiedRef`)は ref のたびに最大3往復(`/systemalert` →
    /// `/systemui/covering` → `/hittable`)を払っており、同じ画面へ連打するだけの探索でも
    /// 木の数だけ払っていた。**撮り直した fresh 木の指紋が前回と同じなら答えを使い回す**——
    /// この探針が答える3つはどれも「今の画面が何か」を言うもので、木がバイト同一のままなら
    /// 答えも変わらない。
    ///
    /// **健全性の限界(意図した上限)**: 木をバイト同一に保ったまま覆う面が出入りする形
    /// (静止画面の上に Control Center が出た/消えた、等)は、次に木そのものが変わるまで
    /// 再確認しない。見逃しの範囲はそこまでに限られる —— 木が動けば必ず撮り直す
    func memoizedScreenProbe(_ found: ElementInfo, fresh: SnapshotResponse,
                             driver: AppDriver, args: [String: Any]) async -> String {
        let key = Self.engineKey(args)
        let fingerprint = Self.treeFingerprint(fresh)
        if let memo = lastScreenProbe[key], memo.fingerprint == fingerprint {
            return memo.warning
        }
        let warning = await Self.screenNotRepresentedWarning(found, driver: driver)
        lastScreenProbe[key] = (fingerprint, warning)
        return warning
    }

    /// **SpringBoard のアラートが前面に出ていることを名指しする**(iOS xcuitest だけ)。
    ///
    /// DSL 側は `SystemUIGate` + `StepExecutor.unregisteredSystemAlert` で同じ判定をしている
    /// (CLAUDE.md「システムアラートの判定は2段」)。MCP には launch 系ツールしか呼ばず、
    /// この関数自体は判定を持たない(`SystemUIGate.isCovered`/`describeUnregistered` を転送する
    /// だけ)—— 判定は1箇所、文言はここ。
    ///
    /// **NoteCatalog の対象外**: あちらは木だけから決まる注記の唯一の定義元だが、これは
    /// 木の外(`/systemalert`)からの申告で、`backgroundNote`/`switchedNote` と同じ扱い
    /// (NoteCoverageTests.testSnapshotBodyEmitsOnlyCatalogNotes がこの形を許容している)。
    ///
    /// **呼び出し元が2つ**: `snapshotBody` は `systemAlertProbePending` が立っているときだけ
    /// (launch 直後の1回)、`screenNotRepresentedWarning` は ft_tap のたびに毎回
    /// (systemUICoveringWarning と同じく費用は MCP のタップ経路だけで既に許容されている)。
    /// 答えられない(旧ブリッジ・in-app・Android)/ 出ていないときは黙る
    static func systemAlertNote(driver: AppDriver) async -> String {
        guard let probe = try? await driver.systemAlert(), SystemUIGate.isCovered(probe)
        else { return "" }
        let described = SystemUIGate.describeUnregistered(probe)
        let what = described.map { "a system alert (\($0))" } ?? "a system alert"
        return "note: \(what) is in front of the app — the tree below is the app behind it;"
            + " nothing in it is reachable and the alert is drawn by SpringBoard so it never"
            + " appears here. Read it with `ft_launch bundleId: com.apple.springboard`,"
            + " tap its button by ref, then `ft_launch` your app again."
    }

    /// **SpringBoard の面がアプリを覆っている**ことを SpringBoard に聞く(iOS xcuitest だけ)。
    ///
    /// `treeDoesNotMatchScreenWarning` では拾えない形を埋める —— コントロールセンター /
    /// 通知センターはアプリを前面のまま覆うので、木も `XCUIApplication.state` も `/hittable` も
    /// 全部「正常」を返す(実機 iPhone SE3 で実測)。**アプリ側には知る手段が無い**。
    ///
    /// **費用**: `/systemalert` と同じ「目印を1問聞くだけ」の口。**MCP のタップ経路だけ**に置く ——
    /// エージェントは1手ずつ撃つので影響しないが、DSL は1 run で数千回撃つ。DSL へ広げるのは
    /// 実害を観測してから(2026-08-28 時点で DSL での観測は0件)。
    /// **警告のみ**(拒否しない)。答えられない(旧ブリッジ・in-app・Android)ときは黙る
    static func systemUICoveringWarning(_ found: ElementInfo, driver: AppDriver) async -> String {
        guard let covering = try? await driver.systemUICovering(), covering.covering
        else { return "" }
        let surface = covering.marker == "SBCoverSheetWindow"
            ? "the notification centre (or the lock screen)" : "Control Center"
        return " (warning: \(surface) is drawn over the app right now, so \(RefGuard.describe(found))"
            + " is not actually reachable — the element list still shows what is underneath,"
            + " because the covering surface belongs to another process and never appears in it."
            + " This tap landed on that surface. Dismiss it first, then read the screen again)"
    }

    /// **木が画面を代表していないことを、木の外から知る唯一の答え**(iOS xcuitest だけ)。
    ///
    /// アプリが**問い合わせ対象でなくなった**とき(アプリスイッチャーが開いた・別アプリが前面に
    /// 来た)、`/snapshot` は**直前と1バイト同じ木**を返し続け、`XCUIApplication.state` も
    /// `foreground: true` のままになる(実機・Simulator の両方で実測)。木由来の判定は全部素通しする。
    /// **唯一食い違うのがライブのヒットテスト** —— 木が今まさに載せている要素を引き当てられない。
    ///
    /// 実測(2026-08-28・Simulator の設定 root): 覆い無し 0/12 → アプリスイッチャーで 12/12。
    /// 実害の witness は同じ形で `ft_tap` が **`tap [5] done. (selector: #com.apple.settings
    /// .primaryAppleAccount)` と成功を返しながら、実際にはスイッチャーの別アプリのカードに
    /// 当たって端末ごと別アプリへ切り替わった**こと。
    ///
    /// **拾えない形(実測して確定・文言で名乗らないこと)**: **コントロールセンター / 通知センター**は
    /// この信号を出さない —— アプリは前面のまま問い合わせに答え続けるので、全画面を覆われていても
    /// `hittable: true` が返る(Simulator と実機 iPhone SE の両方で確認)。あちらは
    /// **別の手当てが要る未解決の穴**(docs/mcp-audit-rounds.md の当該ラウンド)
    ///
    /// **絞り込みは `TapTargetGeometry.platformShouldResolve`**(名前を持たない容器は覆いが
    /// 無くても引き当てられないので、そのまま信号にすると誤検知だらけになる。実測は同 doc)。
    /// **警告のみ**(拒否しない)。答えられない(旧ブリッジ・in-app・Android)ときは黙る。
    ///
    /// **費用**: 対象1件で 72〜146ms。**MCP のタップ経路だけ**に置く —— こちらは
    /// エージェントが1手ずつ撃つので影響が無い。DSL は1 run で数千回撃つため、
    /// 同じ費用を毎ステップ払う判断は実測してから(今回は入れていない)
    static func treeDoesNotMatchScreenWarning(_ found: ElementInfo,
                                              driver: AppDriver) async -> String {
        guard TapTargetGeometry.platformShouldResolve(found),
              (try? await driver.hitTest(ref: found.ref)) == .unresolvable
        else { return "" }
        return " (warning: the platform cannot find \(RefGuard.describe(found)) at all, even though"
            + " the tree just listed it — the app is no longer the one being queried (the app"
            + " switcher is open, or another app came to the front), and the tree still shows what"
            + " was there before. This tap almost certainly did not reach the app."
            + " Check with ft_screenshot, and bring the app back before operating it)"
    }

    /// **木では答えられない「上のクロムの下へ潜っているか」をプラットフォームに聞く**(iOS だけ)。
    ///
    /// ゲートは `TapTargetGeometry.suspectedHiddenUnderChrome`(粗くてよい。断定は
    /// ヒットテストに委ねる)。**疑ったときだけ1件聞く** —— 全要素に付けると実測 5.1 秒
    /// = snapshot の 50 倍で、常時は払えない(`AppDriver.hittable` の doc)。
    ///
    /// **答えられないとき(nil)は黙る**: 旧ブリッジ・引き当て不能・Android はすべてここ。
    /// 木の限界を別の推測で置き換えないため、`false` と断言されたときだけ言う
    static func hiddenUnderChromeWarning(_ found: ElementInfo, in fresh: SnapshotResponse,
                                         driver: AppDriver) async -> String {
        guard TapTargetGeometry.suspectedHiddenUnderChrome(found, in: fresh.elements,
                                                           screen: fresh.screen),
              (try? await driver.hitTest(ref: found.ref)) == .hittable(false)
        else { return "" }
        return " (warning: the platform reports \(RefGuard.describe(found)) is NOT hittable at its"
            + " reported position — it is scrolled under the navigation bar or another overlay, so"
            + " this tap most likely landed on whatever is drawn there. Scroll it into view first)"
    }

    /// 2台目も MCP で撮っていたからで、**撮っていない宛先へ撃つ形が丸ごと抜けていた**。
    /// 素通しは `nextRefBase == 0`(このセッションが ref を1つも発行していない)ときだけにする。
    /// 返す ref は**セッション ref**(ブリッジへ渡す前に呼び手が `nativeRef` を通すこと)
    func verifiedRef(_ ref: Int, driver: AppDriver,
                             args: [String: Any]) async throws -> (ref: Int, note: String) {
        guard let resolved = resolveSessionRef(ref, args: args) else {
            guard nextRefBase > 0 else { return (ref, "") }
            if let owner = otherKeyHolding(ref, args: args) {
                throw MCPError(Self.refFromAnotherTargetMessage(
                    ref: ref, takenUnder: owner, firedAt: Self.engineKey(args)))
            }
            throw MCPError("unknown ref [\(ref)] — it is not from any recent snapshot"
                + " (refs are per-snapshot; the last 5 snapshots were checked)."
                + " Take a fresh ft_snapshot")
        }
        let target = resolved.element
        // **isStale の注記を先頭に置く**: 何に当たったかの前に、番号の出所が古いことを言う
        // **先頭は空白・末尾に余白を残さない**(RefGuard の警告群と同じ形。ここだけ裸の
        // "note:" で始まると "done.note:" と密着し、末尾空白は次の " (selector:" と二重になる)
        let staleNote = resolved.isStale
            ? " note: [\(ref)] is from an older snapshot (refs have been renumbered since)."
                + " It was matched as \(RefGuard.describe(target)) and re-located in the current"
                + " tree — prefer refs from the latest snapshot."
            : ""
        let takenFrom = generationSnapshot(containing: ref, args: args)
        let lastRendered = takenFrom?.elements ?? []
        let fresh = try await freshSnapshot(driver, args: args)
        if let message = Self.refFromAnotherAppMessage(
            ref: ref, takenFrom: takenFrom, fresh: fresh) { throw MCPError(message) }
        // **ref の出所についての注記はまとめて先頭に置く**(何に当たったかより前に言う)。
        // 2つは排他 —— screenChangedUnderRefNote は isStale のとき黙る
        let originNote = staleNote + Self.screenChangedUnderRefNote(
            ref: ref, takenFrom: takenFrom, fresh: fresh,
            isStale: resolved.isStale, matched: target)
        // **申告 keyboardFrame はキー面だけ**(サジェストバー・地球儀/Dictate 行を含まない)。
        // 木の chrome で広げ、chrome 自身とその部分木は除外する(KeyboardOcclusion の doc)。
        // DSL 側(StepExecutor+Actions.swift)も同じ型で揃える —— 片方だけ広げると
        // MCP と DSL が同じ画面で違う判断をする
        let keyboardOcclusion = KeyboardOcclusion.resolve(
            reported: fresh.keyboardFrame, in: fresh.elements)
        // **木に出ないオーバーレイ・ウィンドウ**(Android のポップアップ)。keyboardFrame と
        // 同じく申告からしか言えない —— 覆っている実体が fresh.elements に1要素も載らない
        let overlayWindows = OverlayWindowOcclusion.resolve(reported: fresh.overlayWindowFrames)
        switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
        case .gone:
            throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                truncatedCount: fresh.truncatedCount))
        case .ghost(let found):
            // **拒否せず警告して撃つ**(2026-08-06 に方針を後退させた。理由は RefGuard の宣言)。
            // **キーボード被覆は先に言う**(木の遮蔽判定では原理的に拾えない事実なので、
            // 座標由来の他の警告より確度が高い)
            return (found.ref, originNote
                + RefGuard.preTapWarnings(found, keyboardOcclusion: keyboardOcclusion,
                                        overlayWindows: overlayWindows)
                + RefGuard.ghostWarning(found: found, in: fresh.elements, screen: fresh.screen))
        case .found(let found, let moved):
            // **ラベルが変わっていないかも見る**。moved の大小とは無関係に出す ——
            // 動かずにラベルだけ変わった行も同じ危険(RefGuard.labelChangeNote 参照)
            let labelNote = RefGuard.labelChangeNote(old: target.label, new: found.label) ?? ""
            // **ghost でなくても別の物に当たり得る**2形(上に描かれた overlay / 同一矩形への
            // 積み重なり)。どちらも容器の内側なので RefGuard.relocate では .found になる
            let overlap = originNote
                + RefGuard.preTapWarnings(found, keyboardOcclusion: keyboardOcclusion,
                                        overlayWindows: overlayWindows)
                + RefGuard.overlapWarning(found: found, in: fresh.elements, screen: fresh.screen,
                                        isAndroid: Self.platformName(args) == "android")
                + (await Self.hiddenUnderChromeWarning(found, in: fresh, driver: driver))
                // SpringBoard に attach している間は「面がアプリを覆っている」系の注記を出さない
                // —— その面(許可アラート等)のボタンを撃っている最中に「SpringBoard へ attach して
                // 読め」と言うことになる(実機 iPhone 13 で実際に出た)
                + (launchedBundleIDs[Self.engineKey(args)] == "com.apple.springboard" ? ""
                    : await memoizedScreenProbe(found, fresh: fresh, driver: driver, args: args))
            guard moved >= RefGuard.movedThreshold else { return (found.ref, overlap + labelNote) }
            // **原因までは断定できない**が、「他も同じだけ動いたか」は手元の2枚から言える。
            // 揃って動いていればスクロール等の画面全体の移動、その要素だけならレイアウト変化。
            // 切り分けの手掛かりとして出す(外部フィードバック 2026-08-06。severity は低いとのこと)
            let cause = RefGuard.movedTogether(target, found,
                                               before: lastRendered, after: fresh.elements)
            return (found.ref, originNote
                + RefGuard.preTapWarnings(found, keyboardOcclusion: keyboardOcclusion,
                                        overlayWindows: overlayWindows)
                + RefGuard.movedNote(found: found, moved: moved, cause: cause) + labelNote)
        }
    }

    /// 要素が出るまでスクロールして探す。**探索そのものは DSL と同じ StepExecutor に委ねる**。
    ///
    /// 自前でスワイプのループを書かない理由: 整定待ち・キャッシュ回避・容器基準の刻み・
    /// ghost の掴み直し・飛び越しの拾い直し・打ち切りは全部 StepExecutor に入っており、
    /// **同じ知見の2つ目の実装を作ると必ず割れる**(docs/design.md の「契約は1箇所」)。
    /// ここは FlowStep を1つ組んで投げるだけにする = MCP で届く要素はシナリオでも届く。
    /// `scrollFrame` 引数の解決結果。**ref(整数)は rect へ、文字列は従来どおり locator へ**
    /// (FlowStep.scrollFrameRect 参照)。`original` は ref 経由のときだけ埋まり、
    /// シート展開後に同じ要素を撮り直した木から再照合して rect を作り直すのに使う
    /// **ft_scroll_to と ft_swipe が共有する**(解決の2つ目の実装を作らない)
    struct ScrollFrameArg {
        var locator: FlowLocator?
        var rect: FTRect?
        var original: ElementInfo?
        var note: String = ""
    }

    /// **ref はセレクタが書けない容器のための逃げ道**(id の重複・欠落。2026-08-10)。
    /// 既存の stale-ref 再照合(resolveSessionRef → RefGuard.relocate)を通してから frame を取る ——
    /// verifiedRef と同じ規律で、撮った時点から動いていても黙って古い座標を使わない
    func resolveScrollFrameArg(_ args: [String: Any], driver: AppDriver) async throws
        -> ScrollFrameArg {
        if let ref = args["scrollFrame"] as? Int {
            guard let resolved = resolveSessionRef(ref, args: args) else {
                throw MCPError("scrollFrame ref [\(ref)] is unknown — it is not from any recent"
                    + " snapshot (refs are per-snapshot; the last 5 snapshots were checked)."
                    + " Take a fresh ft_snapshot")
            }
            let target = resolved.element
            let takenFrom = generationSnapshot(containing: ref, args: args)
            let fresh = try await freshSnapshot(driver, args: args)
            // **ref を食う3つ目の経路**(2026-08-13 の掃討漏れ)。verifiedRef / verifiedElement /
            // ここ、で全部。容器の ref も id・ラベルで再照合されるので、放置すると
            // **別アプリの同名容器の中でジェスチャが走る**
            if let message = Self.refFromAnotherAppMessage(
                ref: ref, takenFrom: takenFrom, fresh: fresh) { throw MCPError(message) }
            switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
            case .gone:
                throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                    truncatedCount: fresh.truncatedCount))
            case .ghost(let found), .found(let found, _):
                // **rect にできない容器を黙って渡さない**: 幅か高さが0だと、これを起点にした
                // ジェスチャは1px も動かせる場所を持たない
                guard found.frame.width > 0, found.frame.height > 0 else {
                    throw MCPError("scrollFrame ref [\(ref)] \(RefGuard.describe(found)) has a"
                        + " zero-size frame, so there is nothing to swipe inside")
                }
                var note = RefGuard.labelChangeNote(old: target.label, new: found.label) ?? ""
                // **ref はどんな要素の frame も掴める**(scrollable 申告を確かめない —— それが
                // この逃げ道の存在意義: id の重複・欠落で選べない容器も frame さえ分かれば渡せる)。
                // ただし黙って撃つと「マークされた容器の中を振った」という誤った印象を残すので、
                // 申告が無い(true でない)ときは出所を名乗る
                if found.scrollable != true {
                    note += Self.scrollFrameNotDeclaredScrollableNote(found)
                }
                return ScrollFrameArg(rect: found.frame, original: target, note: note)
            }
        }
        if let text = args["scrollFrame"] as? String {
            return ScrollFrameArg(locator: FTSelector.parse(text).primary)
        }
        return ScrollFrameArg()
    }

    /// scrollFrame に ref で渡された要素が `scrollable` を申告していないときの但し書き。
    /// **セレクタ依存の本文であって木だけから決まる注記ではないので NoteCatalog には登録しない**
    /// (multiMatchHint と同じ扱い)
    static func scrollFrameNotDeclaredScrollableNote(_ found: ElementInfo) -> String {
        " (the swipe area was taken from [\(found.ref)] \(RefGuard.describe(found))'s frame"
            + " (\(Int(found.frame.x)),\(Int(found.frame.y))"
            + " \(Int(found.frame.width))x\(Int(found.frame.height)));"
            + " it does not declare itself scrollable, so the gesture is a plain drag inside"
            + " that rectangle)"
    }

    /// シート展開救済の高さ計測(sheetExpansionGrew / sheetShrunkAfterRetry の入力)。
    /// ref 形式は同じ要素を再照合、セレクタ形式は DSL と同じ照合の先頭一致で測る。
    /// scrollFrame 未指定なら nil = 判定は黙る(sheetExpansionGrew 側の宣言参照)
    private static func scrollFrameHeight(_ arg: ScrollFrameArg, step: FlowStep,
                                          in snapshot: SnapshotResponse) -> Double? {
        if let original = arg.original {
            guard case .found(let found, _) = RefGuard.relocate(
                original, in: snapshot.elements, screen: snapshot.screen) else { return nil }
            return found.frame.height
        }
        guard let locator = step.scrollFrame else { return nil }
        return StepExecutor.resolvedCandidates(locator, elements: snapshot.elements)?
            .first?.frame.height
    }

    /// `StepExecutor` を組むための2つの入力(releasesScrollTouch の反転元 / 空打ちゲート用
    /// uiFramework)。**scrollTo と ft_batch が共有する**(2つ目の判定を作らない) ——
    /// releasesScrollTouch は **iOS だけ true**(Android では 2pt のドラッグがクリックとして
    /// 発火する。StepExecutor の宣言参照)。ここを取り違えると探索直後に行が勝手に選択される。
    /// uiFramework ヒント: xcuitest は profile 経由ならドライバ生成時にバンドルマーカーで
    /// 判定済み(uiFrameworkHints)。in-app/hybrid は自己申告(status)を engineKey ごとに
    /// 1回だけ取得して使い回す。Android は releasesScrollTouch=false で無関係。
    /// **残穴は profile 無しの xcuitest だけ**(任意の前面アプリを駆動するため対象 bundleID が
    /// 無くマーカー判定もできない → nil = 空打ちは従来どおり打たれる)
    func resolveExecutorHints(_ driver: AppDriver, args: [String: Any]) async
        -> (isAndroid: Bool, uiFrameworkHint: String?) {
        let key = Self.engineKey(args)
        let engineForKey = engines[key]
        let isAndroid = engineForKey == "android" || driver is AndroidDriver
        guard !isAndroid else { return (true, nil) }
        if let cached = uiFrameworkHints[key] { return (false, cached) }
        if engineForKey == "xcuitest" {
            // profile 無しでも、resolver が udid を特定できていれば、attach 中のアプリ
            // (status.sessionBundleID)のバンドルマーカーで判定できる(成功だけ記憶)
            if let udid = udids[key] ?? nil,
               let bundleID = (try? await driver.status())?.sessionBundleID,
               let hint = AppBundleInspector.detect(udid: udid, bundleID: bundleID,
                                                    physical: false) {
                uiFrameworkHints[key] = hint
                return (false, hint)
            }
            return (false, nil)
        }
        let hint = (try? await driver.status())?.uiFramework
        if let hint { uiFrameworkHints[key] = hint }
        return (false, hint)
    }

    /// **セレクタ解決の唯一の実装**(FTSelector.parse → [primary]+fallbacks →
    /// StepExecutor.resolvedCandidates)。`matches`(MCPServer+Driver.swift)はこの結果が
    /// 空かどうかを見るだけの薄いラッパー — 2つ目の照合ロジックを作らない。ここは当たった
    /// 要素そのものが要る呼び手(scrollTo の画面外再確認)用
    static func matchedElements(_ selectorText: String, in snapshot: SnapshotResponse) -> [ElementInfo] {
        let parsed = FTSelector.parse(selectorText)
        return ([parsed.primary] + parsed.fallbacks).flatMap {
            StepExecutor.resolvedCandidates($0, elements: snapshot.elements) ?? []
        }
    }

    /// `ft_scroll_to` 成功文に添える多重ヒットの注記(2026-08-12 監査)。**セレクタ依存の本文**
    /// であって木だけから決まる注記ではないので NoteCatalog には登録しない
    /// (NoteCoverageTests のソース走査対象は木由来の注記だけ)
    static func multiMatchHint(_ matched: [ElementInfo]) -> String {
        guard matched.count >= 2 else { return "" }
        return " (\(matched.count) elements match this selector; the first in tree order was used)"
    }

    /// 「この画面ではシート展開救済が効かない」の記録(`sheetRescueKey` 参照)。
    /// **上限を切る**: セッションが長いほど画面の数だけ指紋が溜まるので、古いものから捨てる
    /// (救済が効かない画面は数個で、10 も覚えれば往復は止まる)
    func rememberFutileSheetRescue(_ snapshot: SnapshotResponse, args: [String: Any]) {
        let key = Self.engineKey(args)
        var keys = sheetRescueFutile[key] ?? []
        if keys.count >= Self.sheetRescueMemoryCap { keys.removeFirst() }
        keys.insert(Self.sheetRescueKey(snapshot))
        sheetRescueFutile[key] = keys
    }

    static let sheetRescueMemoryCap = 10

    func scrollTo(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let selectorText = args["selector"] as? String, !selectorText.isEmpty else {
            throw MCPError("selector is required (same syntax as the DSL: #id, a label, .type, a||b)")
        }
        guard let direction = FTScrollDirection(rawValue: args["direction"] as? String ?? "down") else {
            throw MCPError("direction must be one of down/up/right/left (content direction)")
        }
        let scrollDriver = try await driver(args)
        // **曖昧さは「渡す前に見えていた画面」で判定する**: 探索後の木で数えると、リストが
        // 読み込み直しに入っている回に同名の容器が1つしか残らず黙ってしまう
        // (2026-08-07 実測。Google マップは探索スワイプのたびに結果を組み直す)
        let beforeScroll = lastSnapshots[Self.engineKey(args)]
        let selector = FTSelector.parse(selectorText)
        let scrollFrameArg = try await resolveScrollFrameArg(args, driver: scrollDriver)
        var step = FlowStep(
            action: "scrollTo", locator: selector.primary,
            fallbacks: selector.fallbacks.isEmpty ? nil : selector.fallbacks,
            direction: direction.swipe.rawValue,
            maxSwipes: args["maxSwipes"] as? Int ?? FlowStep.defaultMaxSwipes,
            scrollFrame: scrollFrameArg.locator,
            scrollFrameRect: scrollFrameArg.rect)
        let scrollFrameLabelNote = scrollFrameArg.note.isEmpty ? ""
            : "note: the scrollFrame ref was re-checked against the current tree\(scrollFrameArg.note).\n"
        let (isAndroid, uiFrameworkHint) = await resolveExecutorHints(scrollDriver, args: args)
        // **1回目だけ半開きシートの逆走査を後回しにする**(defersPartialSheetRecovery の宣言参照):
        // sheetCollapsed なら下でシートを展開して再試行し、その再試行が全画面高で同じ救済を
        // 持つので、畳まれた視界での逆走査(実測 7.8s)は丸損になる
        let executor = StepExecutor(driver: scrollDriver,
                                    releasesScrollTouch: !isAndroid, isAndroid: isAndroid,
                                    uiFramework: uiFrameworkHint,
                                    defersPartialSheetRecovery: true)
        // **所要時間の内訳の起点**: (a) 1回目の探索 + (b) シート展開救済だけを測る
        // (driver 解決・scrollFrame 解決は上ですでに終わっている)。成功応答だけに載せる
        let timingClock = ContinuousClock()
        let timingStart = timingClock.now
        var outcome = await executor.execute(step)
        // **必ず撮り直す**(0スワイプで見つかった回も)。executor が解決に使った木を再利用して
        // 1枚ぶん(iOS 実測 2.0s)節約する案は 2026-08-12 に実装して**撤回**した ——
        // 撮り直しは節約ではなく**独立した砦**で、これを省くと「対象が返す木から消えている」
        // (MCPRefGuardTests)と「中心が画面外へ動いた」(MCPScrollToOffscreenGateTests)の
        // 2つのゲートが構造的に無効になる。後者は **0スワイプの witness を持つ**
        // (Apple マップの経路ページャが読み取りの合間に自分で動く)ので、スワイプ数では守れない
        var after = try await freshSnapshot(scrollDriver, args: args)
        // **半開きシートは自分で広げて1度だけやり直す**。この形は失敗文で
        // 「グラバーを上へ引け」と案内済みだったが、**案内できるなら自分でできる** ——
        // 実測(Apple マップの経路詳細)では、案内どおり ft_drag してから同じ ft_scroll_to を
        // 撃ち直すだけで通り、2往復を人手で払っていた。
        // 条件は StepExecutor と共有(StepNote.sheetCollapsed)。**グラバーを名前で特定できる
        // ときだけ**動かす —— 当てずっぽうのドラッグは地図やリストを勝手に動かす
        var sheetNote = ""
        var rescueMs: Int?
        // **同じ画面で2度は撃たない**(2026-08-12 の監査): 救済は実測 21.2 秒かかるのに、
        // 1回目が「3回目も同じ」と結論した画面で ft_scroll_to を撃ち直すと全額を再び払っていた。
        // 鍵は木の指紋(sheetRescueKey)—— 画面が変われば指紋も変わるので、記憶は自然に失効する
        let rescueKey = Self.sheetRescueKey(after)
        let rescueKnownFutile = sheetRescueFutile[Self.engineKey(args)]?.contains(rescueKey) == true
        if StepExecutor.isSuccess(outcome.status) {
            // 成功。救済は要らない
        } else if outcome.notes.contains(.sheetCollapsed), rescueKnownFutile {
            sheetNote = Self.sheetRescueMarker + "skipped — the list stopped moving inside a"
                + " partially open sheet again."
                + " Expanding the sheet was already tried on this exact screen earlier in this"
                + " session and did not help, so it was NOT retried this time (that rescue costs"
                + " seconds)." + Self.sheetManualExpandHint(after) + "\n"
        } else if outcome.notes.contains(.sheetCollapsed),
           let grabber = Self.sheetGrabber(in: after) {
            let rescueStart = timingClock.now
            let beforeExpansion = after
            let beforeHeight = Self.scrollFrameHeight(scrollFrameArg, step: step,
                                                      in: beforeExpansion)
            let toY = after.screen.height * Self.expandedSheetTopRatio
            try await scrollDriver.drag(fromX: grabber.frame.centerX, fromY: grabber.frame.centerY,
                                        toX: grabber.frame.centerX, toY: toY,
                                        pressSeconds: 0.05, durationSeconds: 0.5)
            // **rect は展開後の木で作り直す**: シートが伸びると scrollFrameRect の元になった
            // 容器の frame も変わるので、展開前の rect のまま撃つと広がった分を探索できない。
            // 同じ要素を撮り直した木から再照合し、取れなければ従来の rect のまま
            let expanded = try await freshSnapshot(scrollDriver, args: args)
            after = expanded
            if let original = scrollFrameArg.original,
               case .found(let found, _) = RefGuard.relocate(
                   original, in: expanded.elements, screen: expanded.screen) {
                step.scrollFrameRect = found.frame
            }
            let expandedHeight = Self.scrollFrameHeight(scrollFrameArg, step: step, in: expanded)
            // 伸びなかったら再試行しない(判定は sheetExpansionGrew の宣言参照)
            if !Self.sheetExpansionGrew(beforeHeight: beforeHeight,
                                        expandedHeight: expandedHeight) {
                let beforeHeight = beforeHeight ?? 0
                let expandedHeight = expandedHeight ?? 0
                rescueMs = Int((timingClock.now - rescueStart) / .milliseconds(1))
                // **効かなかったことを覚える**(sheetRescueKey 参照)。鍵は救済**前**の木 ——
                // これが次の呼び出しの1回目の探索が行き着く画面だから
                rememberFutileSheetRescue(beforeExpansion, args: args)
                sheetNote = Self.sheetRescueMarker
                    + "— the list had stopped moving inside a partially open sheet, so"
                    + " [\(grabber.ref)] \(RefGuard.describe(grabber)) was dragged up to expand it,"
                    + " but its height did not increase (\(Int(beforeHeight))pt before,"
                    + " \(Int(expandedHeight))pt after) — the sheet cannot be expanded this way,"
                    + " so the search was not retried."
                    + Self.sheetManualExpandHint(after) + "\n"
            } else if let alreadyThere = Self.visibleAfterExpansion(step: step, in: expanded) {
                // **展開しただけで出ていたら、そこで終わり**(2026-08-12 の実アプリ監査)。
                // シートを広げる目的は「隠れていた行を出すこと」なので、出た時点で探索の
                // 目的は達成されている。ここで素通しして再スワイプに入ると、**この画面では
                // リスト内のスワイプが外側シートの折りたたみに化ける**ため、せっかく出した行を
                // 自分で引っ込めて「見つからない」で終わる —— 実測(Apple マップの乗換案内・
                // iOS 27 Simulator): 展開後に同じ探索を手で撃つと 0 スワイプ・512ms で成功するのに、
                // 救済の再試行は 16.9〜20.7 秒かけて失敗していた
                rescueMs = Int((timingClock.now - rescueStart) / .milliseconds(1))
                outcome = StepOutcome(status: .passed, notes: outcome.notes,
                                      resolvedElement: alreadyThere,
                                      scrollSwipes: outcome.scrollSwipes)
                sheetNote = Self.sheetRescueMarker
                    + "— the list had stopped moving inside a partially open sheet, so"
                    + " [\(grabber.ref)] \(RefGuard.describe(grabber)) was dragged up to expand it,"
                    + " which revealed the target — the search was NOT retried."
                    + Self.sheetExpansionLayoutNote(before: beforeExpansion, after: after) + "\n"
            } else {
                // **再試行は逆走査つき**(defers... を外した別 executor)。展開後も稀に部分高の
                // ままのことがあり、そこで再び後回しにすると救済がどこにも無くなる
                let retryExecutor = StepExecutor(driver: scrollDriver,
                                                 releasesScrollTouch: !isAndroid, isAndroid: isAndroid,
                                                 uiFramework: uiFrameworkHint)
                outcome = await retryExecutor.execute(step)
                after = try await freshSnapshot(scrollDriver, args: args)
                rescueMs = Int((timingClock.now - rescueStart) / .milliseconds(1))
                // **再試行後にシートが元より縮んでいたら名指しする**(2026-08-12実測: Apple
                // マップの乗換案内は、リスト端で続けたスワイプが外側シートの折りたたみに化ける。
                // 黙っていると読み手は同じ探索をもう一度撃つ)
                var shrunkNote = ""
                // **再試行も sheetCollapsed で終わったら、その画面の性質として名指しする**
                // (2026-08-12実測: Apple マップの乗換案内は、リスト内のドラッグが外側シートの
                // 折りたたみに化ける。展開→再試行→また畳まれる、を黙って返すと読み手は
                // 3回目を撃つ)。高さ比較(shrunk)より直接的な証拠なのでこちらを優先する
                if !StepExecutor.isSuccess(outcome.status),
                   outcome.notes.contains(.sheetCollapsed) {
                    rememberFutileSheetRescue(beforeExpansion, args: args)
                    shrunkNote = " The retry ended the same way (the sheet collapsed again) —"
                        + " on this screen drags inside the list collapse the outer sheet instead"
                        + " of scrolling it, so a third attempt will not do better. Read the rows"
                        + " already listed (the ⚠️offscreen ones included), or use the app's own"
                        + " controls to reveal the content."
                        + Self.sheetManualExpandHint(after)
                } else {
                    // **基準は「救済前」or「展開直後」の測れたほう**: 最初の探索のスワイプが
                    // シートを畳んでいると救済前の木に容器が居ない(実測)。展開で容器が
                    // 戻ったなら、その高さとの比較で「再試行がまた畳んだ」を言える。
                    // gone(容器ごと消えた)はここでは言わない —— 展開直後の木はシートの
                    // アニメーション中で計測が不安定(実測)。最終木での判定は下の失敗文が持つ
                    let referenceHeight = beforeHeight ?? expandedHeight
                    let finalHeight = Self.scrollFrameHeight(scrollFrameArg, step: step, in: after)
                    if !StepExecutor.isSuccess(outcome.status),
                       Self.sheetRetryContainerState(beforeHeight: referenceHeight,
                                                     finalHeight: finalHeight) == .shrunk {
                        rememberFutileSheetRescue(beforeExpansion, args: args)
                        shrunkNote = " The scroll container ended up SHORTER than before the rescue"
                            + " (\(Int(referenceHeight ?? 0))pt → \(Int(finalHeight ?? 0))pt) — on"
                            + " this screen a swipe at the list's edge collapses the outer sheet"
                            + " instead of scrolling, so repeating the search will not help; read"
                            + " the visible rows or navigate another way."
                            + Self.sheetManualExpandHint(after)
                    }
                }
                sheetNote = Self.sheetRescueMarker
                    + "— the list had stopped moving inside a partially open sheet, so"
                    + " [\(grabber.ref)] \(RefGuard.describe(grabber)) was dragged up to expand it and"
                    + " the search was retried once."
                    + Self.sheetExpansionLayoutNote(before: beforeExpansion, after: after)
                    + shrunkNote + "\n"
                // **最終木も同じ鍵で覚える**: 次の呼び出しの1回目の探索は、この画面から始まって
                // ここへ戻ってくる。救済前・救済後のどちらの指紋で来ても弾けるようにする
                if !shrunkNote.isEmpty { rememberFutileSheetRescue(after, args: args) }
            }
        }
        // **成功は .passed/.passedViaFallback/.healed の3形**(StepExecutor.isSuccess の定義)。
        // fallback 一致も探索としては成功であり、失敗文を投げると内部 enum(FlowLocator ダンプ)が
        // そのまま利用者に見える(2026-08-10 実害)
        guard StepExecutor.isSuccess(outcome.status) else {
            // ここに来る時点で outcome.status は failed/skipped/inconclusive のいずれか
            let reason: String
            switch outcome.status {
            case .failed(let message), .skipped(let message), .inconclusive(let message):
                reason = message
            case .passed, .passedViaFallback, .healed:
                reason = "could not confirm the result"
            }
            // **fail-fast(scrollFrame 未解決)は別の文で伝える**: 通常の「did not reach the
            // element」はスワイプを何本か送った前提の文言で、fail-fast は1本も送っていないので
            // そのままでは誤解を招く(2026-08-08。StepNote.scrollFrameMissing = DSL と共有した判定)
            if outcome.notes.contains(.scrollFrameMissing) {
                throw MCPError(scrollFrameLabelNote + "scrollTo \"\(selectorText)\": \(reason)"
                    + Self.scrollAlternativesHint(beforeScroll ?? after))
            }
            // **渡された scrollFrame 容器が最終木から消えていたら名指しする**(2026-08-12実測:
            // Apple マップの乗換案内は探索スワイプがシートごと畳み、最終画面が地図だけになる。
            // 探索開始時には実在した容器(無ければ scrollFrameMissing で上の分岐に入る)なので、
            // 消えたのは探索中 = 同じ探索を繰り返しても届かない)。判定は**最終木**で行う ——
            // 展開直後の木はシートのアニメーション中で計測が不安定(実測)
            var containerGoneNote = ""
            if scrollFrameArg.original != nil || step.scrollFrame != nil,
               Self.scrollFrameHeight(scrollFrameArg, step: step, in: after) == nil {
                containerGoneNote = "note: the scrollFrame container itself is GONE from the final"
                    + " tree — the search swipes collapsed or closed the outer sheet, so repeating"
                    + " the same search will not help. Reopen the sheet (tap the control that"
                    + " showed it) and read the visible rows, or use ft_swipe one screenful at a"
                    + " time instead.\n"
            }
            // **止まった時点で見えているものを一緒に返す**(外部フィードバック 2026-08-06)。
            // 「届かなかった」だけだと ft_snapshot の往復が要るうえ、**記法の誤りに気づけない**
            // —— 素のラベルは完全一致なので、「端末情報」は「端末情報を表示」に当たらない。
            // 候補を見せれば、綴り違いなのか記法(`*…*`)不足なのかがその場で分かる
            // **やり直し済みなら先に言う**: 言わないと読み手は失敗文のシート展開ヒントを
            // 読んで**もう一度同じことを手で試す**(そのぶん往復が増える)
            // **内訳は失敗側にも出す**: 実測で 7.8 秒かけて届かなかった回に何も出ず、
            // 何本振ったのかも分からなかった —— 遅さの説明が最も要るのはこちら
            // **シートが原因の失敗には必ず具体手順を添える**(2026-08-12 の監査)。救済を
            // 撃たなかった/撃てなかった回(グラバーは居るのに `.sheetCollapsed` が立たない、
            // 記憶で省いた等)は、FTCore 側の総称ヒント「drag its grabber upward」で終わっており、
            // 読み手は毎回 ref と目標 y を自分で組み立てていた。**sheetNote が既に出していたら足さない**
            let manualExpand = sheetNote.contains("ft_drag fromRef:") ? ""
                : ((outcome.notes.contains(.sheetCollapsed) || !sheetNote.isEmpty)
                   ? Self.sheetManualExpandHint(after) : "")
            // **探索中の打ち切りは最終木からは分からない**(2026-08-12 のブラウザ監査):
            // 目的の行が画面に入っていた周回で上限に当たっていても、通り過ぎた先の最終画面が
            // 上限内なら `truncationHint(after)` は黙る。実測の2回のうち1回がこれで、
            // 「見つからない」だけを読んだ結果、同じ探索をもう一度撃って 45 秒を捨てた
            let truncatedDuringSearch = outcome.notes.contains(.truncatedDuringSearch)
                && after.truncatedCount == 0
                ? " note: the tree hit the element limit at some point during this search, so the"
                    + " target may have been dropped from the candidates rather than absent —"
                    + " read the screen it should be on with ft_snapshot maxElements:"
                    + " \(BridgeAPI.maxSnapshotElementsCeiling) before concluding it is not there.\n"
                : ""
            throw MCPError(scrollFrameLabelNote + sheetNote + containerGoneNote
                + truncatedDuringSearch
                + Self.scrollTimingNote(totalMs: Int((timingClock.now - timingStart)
                                                     / .milliseconds(1)),
                                        swipes: outcome.scrollSwipes, rescueMs: rescueMs)
                + "scrollTo \"\(selectorText)\" did not reach the element"
                + " (\(reason))\(manualExpand)\(Self.truncationHint(after))."
                + " \(Self.visibleLabelsHint(after))"
                + Self.scrollNotationHint(selectorText, after: after, beforeScroll: beforeScroll,
                                          backDirection: Self.reversedDirection(direction))
                + Self.similarLabelsHint(selectorText, in: after)
                + Self.scrollAreaHint(beforeScroll ?? after, args: args))
        }
        // **成功と言う前に、返す木にそれが居ることを確かめる**(2026-08-06 の探索で外した)。
        // 探索のスワイプは**ボタンを発火させることがある**(SwiftUI の SUT で実測)。
        // その場合 executor は途中の観測で passed のまま、撮り直した木は**別画面**になり、
        // 「scrolled to #nav_diagnostics」+ `#nav_diagnostics` が居ない木、が返っていた。
        // 決定的再現: E2E-iOS のホームで `#nav_diagnostics`(下部タブの下にある行)
        // **照合は selector で行う**: `scrollTo` は `resolvedElement` を載せない
        // (StepExecutor の scrollTo 経路は要素を掴んでも記録しない)ので、それを当てにすると
        // この検査は一度も走らない。`matches` は waitFor と同じ = DSL と同じ照合
        if !Self.matches(selectorText, in: after) {
            throw MCPError("scrollTo \"\(selectorText)\" reached the element, but it is gone from"
                + " the screen now — the search itself changed the screen"
                + " (a swipe over a tappable row can fire it)\(Self.truncationHint(after))."
                + " \(Self.visibleLabelsHint(after))"
                + " Go back to the screen that has it and retry;"
                + " scrollFrame: <container> keeps the swipes inside the list."
                + Self.scrollAreaHint(after, args: args))
        }
        // **木に居ること ≠ 画面に居ること**: FTCore 側のゲート(runScrollSearch)を通っても、
        // ここは独立した砦として残す。当たった要素が**すべて**中心画面外なら、探索は届いていない
        // (弾切れで振り出しへ戻っただけ)。**executor と同じサイズ免除付きゲートを使う**
        // (TapTargetGeometry.offscreenScrollGateAdvisory) —— 素の offscreenAdvisory のままだと、
        // ビューポートより大きい要素で executor 側は成功しているのにここだけ hard fail する
        // 不整合になる(上の「画面が変わった」エラーとは原因が別なので文も分ける)
        let matchedInTree = Self.matchedElements(selectorText, in: after)
        if !matchedInTree.isEmpty,
           matchedInTree.allSatisfy({
               TapTargetGeometry.offscreenScrollGateAdvisory(for: $0, screen: after.screen) != nil
           }) {
            throw MCPError("scrollTo \"\(selectorText)\" is in the tree but its centre is still off"
                + " screen (⚠️offscreen) — the search ran out of swipes without actually reaching it"
                + "\(Self.truncationHint(after)). \(Self.visibleLabelsHint(after))"
                + " Pass scrollFrame: <container> to keep the swipes inside the right scroll area"
                + " instead of falling back to a whole-screen swipe."
                + Self.scrollAreaHint(beforeScroll ?? after, args: args))
        }
        // fallback 一致は成功だが、利用者が書いた式では見つからなかったことを伝える
        // (primary が空振りする式は将来また空振りしうる)
        var fallbackNote = ""
        if case .passedViaFallback(let locator) = outcome.status {
            fallbackNote = " (matched via the fallback \(locator.summary))"
        }
        // outcome.resolvedElement は StepExecutor が内部で撮った木の native ref を持っている
        // (MCP の ref 世代管理を経由していない)。表示するのは `after`(adoptSnapshot 済み =
        // セッション ref)の番号でなければ tap に使えないので、同一性で引き直す
        var landed = ""
        if let resolved = outcome.resolvedElement {
            switch RefGuard.relocate(resolved, in: after.elements, screen: after.screen) {
            case .found(let found, _), .ghost(let found):
                landed = " → [\(found.ref)] \(RefGuard.describe(found))"
            case .gone:
                landed = ""
            }
        }
        // **多重ヒットは黙らない**(2026-08-12 監査): 木順の先頭を掴むのは既定挙動のままだが、
        // 他にも当たりがあったことを言わないと「別の意図しない要素に静かに命中した成功」を
        // 見分けられない(実測: tenki.jp で "*週間*" がタブ「2週間」に当たり、週間予報の行は
        // 無視された)。件数は `matchedInTree` で計算済み = 追加コストは無い
        landed += Self.multiMatchHint(matchedInTree)
        // **木を返す口はすべて名指しする**(2026-08-06 の掃討で漏れを見つけた)。上の再確認は
        // 「セレクタが居るか」しか見ないので、**別アプリに同じ id がある**と素通しする ——
        // E2E の 4 SUT は id・ラベルが共通契約なので、これは現に起こり得る形
        let switched = Self.switchedAppNote(
            launched: launchedBundleIDs[Self.engineKey(args)], snapshot: after)
        // scrollFrame を渡すべき当人なので、複数領域の注記もここに出す(欠陥⑪)
        let scrollAreaNote = args["scrollFrame"] == nil ? (ScrollFrameCandidates.note(after) ?? "")
            : Self.lineNote(Self.scrollAreaHint(beforeScroll ?? after, args: args))
        // **利用者が渡した式をそのまま残す**(F): 探索はセレクタで書くのが DSL の形なので、
        // ここだけは解決後の要素ではなく渡された式が正しい下書きになる
        var scrollStep = FlowStep(action: "scrollTo", locator: selector.primary)
        scrollStep.direction = direction.swipe.rawValue
        if args["scrollFrame"] != nil { scrollStep.note = "scrollFrame was used during exploration" }
        // 一覧に**スワイプ方向を出さない**: `direction.swipe` は指の動き(下を読むなら up)で、
        // 読み手が指定した意味方向とは逆になる。一覧は「どの手か」を見分けるためのものなので、
        // 逆向きの語を出すと `drop:` の選択を誤らせる
        interactions.record(InteractionLog.Entry(
            step: scrollStep, unresolved: nil, summary: "scrollTo \"\(selectorText)\""))
        // **畳み方は snapshotAfter と同じ規則で継承する**(inheritingSnapshotFilters 参照)
        let (treeArgs, inheritedNote) = inheritingSnapshotFilters(args)
        // **ghostNote と render で畳みの有無を揃える**(ft_snapshot と同じ理由)
        let collapsingBulk = treeArgs["expandBulk"] as? Bool != true
        let totalMs = Int((timingClock.now - timingStart) / .milliseconds(1))
        let timingNote = Self.scrollTimingNote(totalMs: totalMs, swipes: outcome.scrollSwipes,
                                               rescueMs: rescueMs)
        // **ghostNote と render で ghostFlags を共有**: 同じ `after` に対する
        // 応答1回ぶんのキャッシュ。SnapshotAnnotationCache のコメント参照(寿命はこの呼び出しだけ)
        let cache = SnapshotAnnotationCache()
        return text(switched + scrollFrameLabelNote + sheetNote + timingNote
            + "scrolled to \"\(selectorText)\"\(landed)\(fallbackNote)."
            + " The refs below are fresh\n" + inheritedNote + scrollAreaNote
            // **ft_snapshot より少ない**(scrollFrame 候補・重複 id 系は出さない)。その差は
            // NoteCatalog の contexts が持つ = 2箇所の並びを読み比べる必要はない
            + catalogNotes(NoteCatalog.Input(snapshot: after, collapsingBulk: collapsingBulk,
                                             cache: cache), context: .scrollTo)
            // **既定で畳む**(expandBulk で戻せる): ft_scroll_to の答えは「探した1つがどこに居るか」
            // なので、地図のピンが数十行並ぶ意味は薄い。ft_snapshot と同じ規則にする
            // (2026-08-10 まではここだけ interactiveOnly を無視して常に全行を出していた)
            + SnapshotRenderer.render(after, flagging: cache.ghostFlags(after),
                                      collapsingBulk: collapsingBulk,
                                      interactiveOnly: treeArgs["interactiveOnly"] as? Bool == true,
                                      unit: Self.coordinateUnit(scrollDriver)))
    }
}
