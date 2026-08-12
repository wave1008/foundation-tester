// 実アプリのスナップショットへ検知を全数で当てる回帰ゲート。
//
// **自前の 4 SUT は遮蔽・積み重なり・中身外しの形を代表しない** —— 2026-08-07 の3ラウンドで、
// 誤検知も真陽性も実アプリでだけ出た(4 SUT では1件も出ない)。だからコーパスを
// Tests/Fixtures/RealAppSnapshots/ に固定して、件数を基準値と突き合わせる。
//
// **「増えていないこと」を見るのが目的**。新しい検知を足したときに、それが雑音になっていないかは
// 自分では分からない(2026-08-07 に4種足した)。基準値を上げるのは、増えた分を1件ずつ見て
// 真陽性だと確かめてからにすること —— 黙って上げると、この砦は現状の追認装置になる。
//
// 別のコーパスへ当てたいときは FT_SWEEP_DIR でディレクトリを差し替える(件数の照合はしない)。

import XCTest
import FTCore
@testable import ftester_mcp

final class SweepHarnessTests: XCTestCase {

    /// 1画面ぶんの検知件数
    struct Counts: Equatable, CustomStringConvertible {
        var ghost = 0, overlay = 0, stacked = 0, misses = 0, disabled = 0, offscreen = 0,
            warnedTappable = 0
        /// keyboard はソフトキーボードに中心を覆われたタップ対象(keyboardFrame を申告する
        /// 新ブリッジの木でだけ非 0 になり得る)。**画面の一時状態**であって要素の恒常的な
        /// 問題ではないので warnedTappable(雑音密度ゲート)には入れない
        var keyboard = 0
        /// sliver は容器の縁で細帯に切れたラベル付き要素(TapTargetGeometry.isClippedSliver)
        var sliver = 0
        /// nested は自分の子孫に中心を横取りされた**対話要素**
        /// (TapTargetGeometry.nestedActionCoveringCentre。2026-08-09 追加)
        var nested = 0
        /// scrolledOut は**申告された**スクロール容器の完全に外に居る要素
        /// (TapTargetGeometry.outsideDeclaredScroller。ghost の推測版では拾えない形)
        var scrolledOut = 0
        var description: String {
            "ghost=\(ghost) overlay=\(overlay) stacked=\(stacked) misses=\(misses)"
                + " disabled=\(disabled) offscreen=\(offscreen) warnedTappable=\(warnedTappable)"
                + " keyboard=\(keyboard) sliver=\(sliver) nested=\(nested)"
                + " scrolledOut=\(scrolledOut)"
        }
    }

    /// 2026-08-07 時点の実測値。**すべて中身を確認済み**:
    /// - `overlay` は全画面シート・app bar・下部フッタが実際に覆っている真陽性
    /// - `misses` は中心が中身のどこにも乗らない容器(`#layers_fab_button` 等)
    /// - `disabled` は E2E-CMP の契約上「押しても何も起きない」2ボタンだけ
    /// - `ghost` と `stacked` は**全画面で 0**(2026-08-07 に誤検知を潰した結果)
    static let baselines: [String: Counts] = [
        // 経路プランナーの移動手段タブ(2026-08-08 採取・版53)。**選択中ノード保持の形**
        // (`other checked`・id もテキストも無い)を含む唯一のフィクスチャ。
        // **ただしこれは採取時点の木の凍結**であって、Java 側 shouldInclude の退行は
        // 落とせない(生きたガードには SUT 側に id 無し selected ウィジェットが要る。未実施)。
        // overlay 6 は全件検分済み: 5件はシートが地図 chrome(#mylocation_button 等)を覆う
        // 真陽性、残る1件(warnedTappable の1)は全画面の地図 clickable の中心に
        // 提案テキストが乗る形 = and-results の「スポンサー ← footer」と同じ受理済みの型
        "and-directions_tabs": Counts(ghost: 0, overlay: 6, stacked: 0, misses: 0, disabled: 0,
                                      offscreen: 0, warnedTappable: 1, keyboard: 0, sliver: 0),
        "and-home": Counts(ghost: 0, overlay: 2, stacked: 0, misses: 2, disabled: 0,
                           warnedTappable: 0),
        // 2026-08-08 採取(キーボード/IME 遮蔽検知の導入時)。keyboard 2 は Gboard の
        // レイアウト選択シートに覆われた候補行で、Emulator 上のプローブで実際にタップが IME に
        // 化けた witness と同一要素 = 真陽性。overlay 1(compass ← 候補行)も描画どおり
        "and-maps_suggest_ime": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 0,
                                       warnedTappable: 0, keyboard: 2),
        // 2026-08-12 採取(アーキタイプ拡張)。**キーパッド**(同じ形の 12 キー格子)。
        // nested 1 は真陽性: `#dialpad_view`(0,1220 1080x1141・clickable)の中心 (540,1790) が
        // その中の `#eight`(377,1779 324x168)の上にある = 容器を撃つと「8」が入る。
        // overlay 1(#fab_container ← #dialpad_call_buttons)は通話ボタン列が FAB の器を覆う実描画どおり。
        // disabled 1 は入力が空のときの Backspace(`#deleteButton`)= 真陽性。
        // **実アプリで初めて `disabled` が出た2枚のうちの1枚**(それまで供給源は自前 SUT だけ)
        "and-dialer_keypad": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 1,
                                    offscreen: 0, warnedTappable: 2, keyboard: 0, sliver: 0,
                                    nested: 1, scrolledOut: 0),
        "and-overflow": Counts(),
        "and-place": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 1, disabled: 0,
                            warnedTappable: 0),
        "and-place_expanded": Counts(ghost: 0, overlay: 11, stacked: 0, misses: 0, disabled: 0,
                                     warnedTappable: 3),
        "and-results": Counts(ghost: 0, overlay: 18, stacked: 0, misses: 2, disabled: 0,
                              warnedTappable: 2),
        // 2026-08-12 採取。**設定ツリー**(Android)。misses 1 は
        // `#homepage_app_bar_regular_phone_view`(非操作の器)の中心が中の `#search_bar` に乗る形 =
        // 既存の「見出し容器」と同型の受理済み。警告付きのタップ対象は0
        "and-settings_root": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 1, disabled: 0,
                                    offscreen: 0, warnedTappable: 0, keyboard: 0, sliver: 0,
                                    nested: 0, scrolledOut: 0),
        // nested 1 は検分済みの真陽性: `#PinnedItemSection`(横スクロールする clickable の帯)の
        // 中心は、その中の `#PinnedTile` の上にある。帯を撃つと1枚のタイルが開く
        "ios-home": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 0,
                           warnedTappable: 1, nested: 1),
        // 2026-08-08 採取(v58 = 間引きの bulk 拡張後)。東京駅カード + 地図 POI 67個の木。
        // overlay 17 の内訳: POI 同士の重なり14(駅構内の高密度で実描画どおり・非操作)/
        // カード見出し系3。misses 2 は見出し容器。すべて非操作なので warnedTappable 0
        "ios-maps_station": Counts(ghost: 0, overlay: 17, stacked: 0, misses: 2, disabled: 0,
                                   warnedTappable: 0),
        // 2026-08-09 採取。**nested 検知の witness**: `#Maps.PlaceTableViewCell` (20,138 362x155) の
        // 中心 (201,215) が、同じセルの中の `#FeaturedInMultipleGuidesContextLineItem`
        // (80,202 205x18) の上にある。Simulator 上で ft_tap がガイド一覧を開いた実測の真陽性。
        // overlay 2(無名 button ← #RichTextLabel / #MultiTextView)は iOS に z が無いことによる
        // 兄弟重なりで、ios-maps_suggest_keyboard と同型の現状固定
        "ios-maps_suggest_guides": Counts(ghost: 0, overlay: 2, stacked: 0, misses: 0, disabled: 0,
                                          offscreen: 0, warnedTappable: 3, keyboard: 0, sliver: 0,
                                          nested: 1, scrolledOut: 0),
        // 2026-08-08 採取。検索候補 + キーボード(keyboardFrame (0,583 402x233))。
        // keyboard 16 はキーボード下の候補行群(Simulator 上のプローブでタップが顔文字キーに化けた
        // witness と同じ画面・同じ形 = 真陽性)。overlay 11 は候補行の button ← MultiTextView
        // 兄弟重なり(iOS は z が無い既知の限界。and-results と同型の現状固定)
        "ios-maps_suggest_keyboard": Counts(ghost: 0, overlay: 11, stacked: 0, misses: 0,
                                            disabled: 0, offscreen: 1, warnedTappable: 9,
                                            keyboard: 16),
        // 2026-08-12 採取。**チャット + ソフトキーボード**(会話を開いて入力欄に焦点)。
        // 全項目0 —— キーボードは出ている(`keyboardFrame` (0,583 402x233))が、その下に
        // タップ対象が1つも無い画面なので `keyboard` も0になる。**「何も出ない実アプリの画面」の
        // 供給源として意味がある**(検知が常に何か出す装置になっていないことの陰性対照)
        "ios-messages_keyboard": Counts(),
        // 2026-08-12 採取。**メディアグリッド**(写真6枚のタイル)。misses 1 は
        // `#PXGGridLayout-Group`(非操作の器)の中心が中のタイルに乗る形 = 受理済みの型
        "ios-photos_grid": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 1, disabled: 0,
                                  offscreen: 0, warnedTappable: 0, keyboard: 0, sliver: 0,
                                  nested: 0, scrolledOut: 0),
        "ios-place": Counts(ghost: 0, overlay: 3, stacked: 0, misses: 2, disabled: 0,
                            warnedTappable: 0),
        // 2026-08-09 採取。**scrolledOut 検知の witness**: 場所カードを送ると
        // `#MUScrollableStackView` (0,72 402x802) の上へ抜けたガイド欄が frame ごと木に残る。
        // scrolledOut 3 は容器3枚(`#CuratedGuidesSection` / `#MUCuratedGuidesSectionView` /
        // その collectionView)。中のセルは「自分の横カルーセルの中」に居るので印が付かず、
        // 代わりに offscreen(中心が画面の外)で拾われる —— 両者は排他ではなく、重い方を先に言う。
        // offscreen 13 と warnedTappable 6 は既存検知の素の結果で、全件が画面外の実座標
        "ios-place_guides_scrolled": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 3,
                                            disabled: 0, offscreen: 13, warnedTappable: 6,
                                            keyboard: 0, sliver: 0, nested: 0, scrolledOut: 3),
        "ios-profile": Counts(),
        // 2026-08-12 採取。**WebView / ブラウザ**(Safari で Wikipedia の記事)。
        // **14 件の overlay を全数検分した結果、10 件は誤検知・4 件は真陽性**:
        // - **誤検知 10 件は「折り返す inline テキスト」**という新しい下位形。web の a11y は
        //   1つの文中の run ごとに矩形を出すが、**折り返した run は前の run と同じ原点で
        //   2行ぶんの高さを持つ**(実測: staticText "A mobile app…"(16,332 254x23)と
        //   link "computer program"(16,332 328x51)は原点が一致し、後者が前者を完全に含む)。
        //   iOS は z を持たないので後着の link が「手前」と読まれるが、その座標に実際に
        //   描かれているのは前の run の字。**既知の「iOS に z が無い」型の一種**であって
        //   新しい欠陥ではないが、**1画面に 10 件出るのはこのコーパスで初めて**
        // - **真陽性 4 件**は下部ツールバー(`#MoreMenuButton` (90,792 48x48) /
        //   `#CapsuleNavigationBar`)がページ本文(y=823〜844 の "The"/"Instagram"/
        //   "photo sharing app on a")を覆う形。ここを撃つとブラウザの chrome に当たる
        // disabled 1 は履歴が無いときの「戻る」(`#BackButton`)= 真陽性。
        // warnedTappable 7 = 誤検知の link 5 + 真陽性の link "Instagram" 1 + disabled 1
        "ios-safari_article": Counts(ghost: 0, overlay: 14, stacked: 0, misses: 0, disabled: 1,
                                     offscreen: 0, warnedTappable: 7, keyboard: 0, sliver: 0,
                                     nested: 0, scrolledOut: 0),
        // 2026-08-12 採取。**設定ツリー**(iOS)。全項目0 —— ios-messages_keyboard と並ぶ陰性対照
        "ios-settings_root": Counts(),
        "sut-cmp_controls": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 0, disabled: 2,
                                   warnedTappable: 2),
        "sut-cmp_home": Counts(),
        // sutec-* は sut-ec-mobile の **iOS in-app** の木(2026-08-08 の in-app 監査で採取。
        // それまで in-app の実樹はコーパスに1枚も無かった)。offscreen は全件確認済みの真陽性:
        // calendar_day の #slot_07 は Simulator 上で無反応タップを実測・#slot_23 とホームの
        // 「カテゴリ」は中心が幾何的に画面外。detail の overlay(説明文 ← #btn_add_to_cart)は
        // タップが実際にカート追加になった実測の真陽性。calendar_day の overlay
        // (#btn_back ← #slot_10)は**確認済みの誤検知**(Simulator 実測: btn_back の中心を
        // 叩くと正常に戻る。slot_08〜10 の frame はヘッダ裏の真っ白な領域を指しており、
        // そこには描かれていない。iOS は z が無く後着の行が「手前」と読まれる既知の限界)
        // —— 挙動の現状を固定する値であって真陽性の追認ではない
        "sutec-calendar_day": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 0,
                                     offscreen: 2, warnedTappable: 3),
        "sutec-detail": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 1,
                               offscreen: 0, warnedTappable: 1),
        "sutec-home": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 0, disabled: 0,
                             offscreen: 1, warnedTappable: 0),
    ]

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/FTesterMCPTests/このファイル
            .deletingLastPathComponent()          // Tests/FTesterMCPTests
            .deletingLastPathComponent()          // Tests
            .appendingPathComponent("Fixtures/RealAppSnapshots")
    }

    static func counts(_ snap: SnapshotResponse) -> Counts {
        let els = snap.elements
        let stacked = RefGuard.stackedRefs(els)
        var c = Counts()
        for e in els {
            let ghost = RefGuard.isUntappableGhost(e, in: els, screen: snap.screen)
            let overlay = RefGuard.overlayCovering(e, in: els, screen: snap.screen) != nil
            let misses = RefGuard.missesItsOwnContent(e, in: els, screen: snap.screen) != nil
            if ghost { c.ghost += 1 }
            if overlay { c.overlay += 1 }
            if stacked.contains(e.ref) { c.stacked += 1 }
            if misses { c.misses += 1 }
            // **production の関数を通す**: ここで `!e.enabled` を自前で見ると、
            // `RefGuard.disabledWarning` を壊してもこのゲートが落ちない(2026-08-07 の
            // 変異テストで実際に素通しした)。検知の回帰を見る砦なので必ず本番経路で数える
            let disabled = !RefGuard.disabledWarning(e).isEmpty
            if disabled { c.disabled += 1 }
            let offscreen = !RefGuard.offscreenWarning(e, screen: snap.screen).isEmpty
            if offscreen { c.offscreen += 1 }
            // **production の関数を通す**(disabled と同じ理由)。判定だけ自前で書くと、
            // 警告の組み立て側を壊してもこのゲートが落ちない
            let nested = RefGuard.nestedActionCoveringCentre(e, in: els) != nil
            if nested { c.nested += 1 }
            let scrolledOut = !RefGuard.scrolledOutWarning(e, in: els).isEmpty
            if scrolledOut { c.scrolledOut += 1 }
            if RefGuard.interactiveTypes.contains(e.type),
               ghost || overlay || misses || stacked.contains(e.ref) || disabled || offscreen
                || nested || scrolledOut {
                c.warnedTappable += 1
            }
            if RefGuard.interactiveTypes.contains(e.type),
               RefGuard.keyboardWarning(e, keyboardFrame: snap.keyboardFrame) != nil {
                c.keyboard += 1
            }
            if RefGuard.isClippedSliver(e, screen: snap.screen) { c.sliver += 1 }
        }
        return c
    }

    private func load(_ url: URL) throws -> SnapshotResponse {
        try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    /// 固定コーパスに対して件数が基準値どおりであること
    func testDetectionCountsMatchTheBaseline() throws {
        let dir = Self.fixtureDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(files.count, Self.baselines.count,
                       "フィクスチャと基準値の数が合っていない: \(files)")
        for file in files {
            let name = String(file.dropLast(".json".count))
            guard let expected = Self.baselines[name] else {
                XCTFail("基準値が無いフィクスチャ: \(name)"); continue
            }
            let actual = Self.counts(try load(dir.appendingPathComponent(file)))
            XCTAssertEqual(actual, expected,
                           "\(name) の検知件数が変わった。**増えた分を1件ずつ見て真陽性だと"
                           + "確かめてから**基準値を更新すること(\(actual) vs \(expected))")
        }
    }

    /// **雑音になっていないこと**: タップ対象のうち警告が付く割合の上限。
    /// 2026-08-07 の実測は実アプリで 0〜10%、自前 SUT の controls 画面だけ 18%
    /// (契約上の無効ボタン2つ = 真陽性)。
    ///
    /// **上限を 30% にしたのは 2026-08-09**: `ios-place_guides_scrolled` は
    /// タップ対象 21 のうち 6 = 28%。内訳はガイドのカルーセル(セル3 + その見出し3)が
    /// **丸ごとカードの上へ送り出された**もので、6件とも中心が画面外の実座標 = 真陽性。
    /// 「一画面の三分の一がスクロールで視界の外」という正当な状態が 20% を超えるので、
    /// **検知の質ではなく画面の状態**で落ちていた。件数そのものの砦は
    /// testDetectionCountsMatchTheBaseline 側で、こちらは粗い臭い取りに留める
    func testWarningDensityStaysLow() throws {
        let dir = Self.fixtureDirectory
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter({ $0.hasSuffix(".json") }).sorted() {
            let snap = try load(dir.appendingPathComponent(file))
            let tappable = snap.elements.filter { RefGuard.interactiveTypes.contains($0.type) }
            guard !tappable.isEmpty else { continue }
            let warned = Self.counts(snap).warnedTappable
            let percent = warned * 100 / tappable.count
            XCTAssertLessThanOrEqual(percent, 30,
                                     "\(file): タップ対象の \(percent)% に警告が付いている"
                                     + " —— 検知ではなく雑音になっていないか見ること")
        }
    }

    /// 基準値の採り直し用(FT_SWEEP_BASELINE=1 のときだけ動く)。**貼り付け用の1行と、
    /// 何が発火したかの明細を両方出す** —— 基準値を上げる前に1件ずつ真陽性を確かめるため
    func testPrintBaselines() throws {
        guard ProcessInfo.processInfo.environment["FT_SWEEP_BASELINE"] == "1" else { return }
        let dir = Self.fixtureDirectory
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter({ $0.hasSuffix(".json") }).sorted() {
            let snap = try load(dir.appendingPathComponent(file))
            let c = Self.counts(snap)
            let name = String(file.dropLast(".json".count))
            print("BASELINE \"\(name)\": Counts(ghost: \(c.ghost), overlay: \(c.overlay),"
                + " stacked: \(c.stacked), misses: \(c.misses), disabled: \(c.disabled),"
                + " offscreen: \(c.offscreen), warnedTappable: \(c.warnedTappable),"
                + " keyboard: \(c.keyboard), sliver: \(c.sliver), nested: \(c.nested),"
                + " scrolledOut: \(c.scrolledOut)),")
            let els = snap.elements
            for e in els {
                let who = RefGuard.describe(e)
                if let hit = RefGuard.overlayCovering(e, in: els, screen: snap.screen) {
                    print("   DETAIL \(name) overlay  \(who) ← \(RefGuard.describe(hit))")
                }
                if let inner = RefGuard.missesItsOwnContent(e, in: els, screen: snap.screen) {
                    print("   DETAIL \(name) misses   \(who) → \(RefGuard.describe(inner))")
                }
                if RefGuard.isUntappableGhost(e, in: els, screen: snap.screen) {
                    print("   DETAIL \(name) ghost    \(who)")
                }
                if !RefGuard.offscreenWarning(e, screen: snap.screen).isEmpty {
                    let f = e.frame
                    print("   DETAIL \(name) offscreen \(who) centre=(\(Int(f.x + f.width / 2)),"
                        + "\(Int(f.y + f.height / 2)))")
                }
                if RefGuard.interactiveTypes.contains(e.type),
                   RefGuard.keyboardWarning(e, keyboardFrame: snap.keyboardFrame) != nil {
                    print("   DETAIL \(name) keyboard \(who)")
                }
                if RefGuard.isClippedSliver(e, screen: snap.screen) {
                    let f = e.frame
                    print("   DETAIL \(name) sliver   \(who) \(Int(f.width))x\(Int(f.height))")
                }
                if let nested = RefGuard.nestedActionCoveringCentre(e, in: els) {
                    print("   DETAIL \(name) nested   \(who) ← \(RefGuard.describe(nested))")
                }
                if let scroller = RefGuard.outsideDeclaredScroller(e, in: els) {
                    print("   DETAIL \(name) scrolled \(who) outside \(RefGuard.describe(scroller))")
                }
            }
        }
    }

    /// 別コーパスを当てるときの口(件数の照合はしない。FT_SWEEP_DIR を渡したときだけ動く)

    func testSweepExternalCorpus() throws {
        guard let dir = ProcessInfo.processInfo.environment["FT_SWEEP_DIR"] else { return }
        for file in try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter({ $0.hasSuffix(".json") }).sorted() {
            let snap = try load(URL(fileURLWithPath: dir).appendingPathComponent(file))
            print("SWEEP \(file) elements=\(snap.elements.count) \(Self.counts(snap))")
        }
    }
}
