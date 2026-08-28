// 注記の発火率と出力コストを固定コーパスの全数で測る台帳。
//
// **動機**(2026-08-12): 実アプリ1本(地図)を繰り返し監査して注記を足し続けた結果、
// 「どの注記がどのアプリで効くのか」を誰も知らないまま NoteCatalog が育っていた。
// バグは有限なので減衰するが、「もっと分かりやすく言えたはず」は無限に出るため、
// 注記には**足す力しか働かない**。ここは消すための材料を出す:
//
// - `baseline` の `fixtures` は**発火した画面の名前そのもの**。地図由来(`ios-`/`and-`)しか
//   並んでいない注記は、そのアプリの形にだけ効いている疑いがある(削除・限定の候補)
// - `bytes` は満額で出したときの合計。**注記の量そのものが回帰の対象**
//   (17回目の監査で iOS の律速がブリッジではなく MCP 層の注記生成だと判明している)
// - **1画面も発火しない注記は落とす**(testEveryNoteFiresSomewhere)
//
// SweepHarnessTests との違い: あちらは **RefGuard の幾何判定**(遮蔽・ghost・画面外)の件数、
// こちらは**応答に載る文字列**。同じコーパスを使うが測っている層が別。
//
// 採り直しは `FT_NOTE_COVERAGE=1 swift test --filter NoteCoverageTests`(貼り付け用の行が出る)。
// **基準値を上げる前に、増えた分がどの画面で出たかを見ること** —— 地図だけで増えたなら、
// それは改善ではなく1アプリへの過適合。

import XCTest
import FTCore
@testable import fleetest_mcp

final class NoteCoverageTests: XCTestCase {

    /// 注記1本ぶんの発火。`fixtures` は発火した画面(辞書順)、`bytes` は満額の合計バイト
    struct Coverage: Equatable, CustomStringConvertible {
        var fixtures: [String]
        var bytes: Int
        var description: String { "fixtures: \(fixtures), bytes: \(bytes)" }
    }

    /// フィクスチャのアーキタイプ。**汎用性を測るための唯一の分類**(接頭辞は OS を表すだけで、
    /// アーキタイプは表さない —— `ios-` に地図も設定もブラウザも居る)。
    ///
    /// **1アプリを深く掘るより、初見のアーキタイプを1つ足すほうが1件あたり安い**
    /// (2026-08-12: 6枚足しただけで、それまで「地図でしか出ない」と見えていた注記のうち
    /// 3本が他アーキタイプでも出ることが分かり、WebView では既知型の誤検知が 10 件出た)。
    /// **フィクスチャを足したらここにも足す**(testEveryFixtureHasAnArchetype が検出)
    static let archetypes: [String: String] = [
        // 地図(Google マップ / Apple マップ)—— 監査を繰り返してきた既存のコーパス
        "and-directions_tabs": "map", "and-home": "map", "and-maps_suggest_ime": "map",
        "and-overflow": "map", "and-place": "map", "and-place_expanded": "map",
        "and-results": "map", "ios-home": "map", "ios-maps_station": "map",
        "ios-maps_suggest_guides": "map", "ios-maps_suggest_keyboard": "map",
        "ios-place": "map", "ios-place_guides_scrolled": "map", "ios-profile": "map",
        // 2026-08-12 に足したアーキタイプ(実アプリ・両 OS)
        "ios-settings_root": "settings", "and-settings_root": "settings",
        "ios-messages_keyboard": "chat",
        "ios-photos_grid": "media",
        "ios-safari_article": "webview",
        "and-dialer_keypad": "keypad",
        // ブラウザ(実 web ページ + ブラウザ自身の操作面)。`webview` とは分ける ——
        // ios-safari_article は「記事の a11y 木」だけで、アドレスバー・オーバーレイ・
        // 広告で動くレイアウトを代表しない
        "ios-browser_nationwide": "browser", "ios-browser_startpage": "browser",
        "and-browser_weather": "browser", "and-browser_urlmenu": "browser",
        // gridWithoutHeaderNote / addressBarNote の witness 対(2026-08-12・同じ tenki.jp
        // 2週間天気ページを Android Chrome / iOS Safari で採取。iOS 側は見出し行がツリーにある
        // 陰性対照)
        "and-browser_weektable": "browser", "ios-browser_weektable": "browser",
        // 2026-08-13 の監査で足した対(Yahoo!天気の週間画面を両 OS で)。iOS 側は
        // **gridWithoutHeaderNote が実アプリで初めて出した誤検知**の witness(見出し行が
        // 値の列と揃っていて鎖の最上行に取り込まれる形)。Android 側は
        // **閾値超えの空白帯が2本ある**形で、最大の1本だけを返していた頃は
        // 週間表の見出しが落ちている側が黙って捨てられていた
        "and-browser_weather_weekly": "browser", "ios-browser_weather_weekly": "browser",
        // jma.go.jp で足した対(2026-08-13)。missingPageContentNote /
        // duplicateRegionNote の witness(NoteCoverageTests.baseline の当該コメント参照)
        "and-browser_jma_notree": "browser", "ios-browser_jma_hscroll": "browser",
        // 2026-08-15 の監査ラウンド(ブラウザ・格子)で足した1枚。Chrome の DNS エラーページ ——
        // **ページが viewport に収まりきり、木がそれを全部公開している**形。
        // webViewGapNote がここで容器の 75% を「落ちたかもしれない」と警告していた誤検知の
        // witness で、`TreeCoverage.pageExtendsBeyondViewport` の陰性対照
        "and-browser_error_page": "browser",
        // 2026-08-15 の監査(gridWithoutHeaderNote の誤検知)で足した対。J1順位表を両OSで採取 ——
        // 見出し行(「順位/クラブ/勝点/…」)は最上行として木に在るのに、room 比のガードだけでは
        // 直上の空きを見出しの欠落と誤読していた(空きの正体は「Ｊ１」「2026/27」セレクタが
        // iOS 側 a11y から落ちている形で、見出しとは無関係)。真陽性(and-browser_weektable)の
        // 陰性対照として `chainsHaveHeaderTopRow` を追加した witness
        "ios-browser_j1_standings": "browser", "and-browser_j1_standings": "browser",
        // iOS Safari・Yahoo 天気トップの1枚(2026-08-15 採取)。**要素上限で
        // 切り詰められた実ページ**(120 要素・89 件脱落)で、代表するのは自己言及の罠 ——
        // **`webView` 要素とアドレス欄そのものが上限で落ちている**(同じ画面を 400 で撮ると
        // 両方居る)。木の中身で「これは web ページか」を判定すると、**切り詰めがひどいほど
        // 判定が効かなくなる** = 検出したい現象が検出器を殺す。`holdsWebContent` が
        // セッションのアプリを第一の根拠にしている理由の witness
        "ios-browser_yahoo_top": "browser",
        "ios-maps_route_options": "picker",
        // 赤羽→立川の乗換案内で採った対(2026-08-16)。**同じ画面の2状態** ——
        // 「出力が長い」と言われた画面そのものを、注記の実数で測るための供給源。
        // 半開きは地図+シート(map)、展開は全画面の手順リスト —— 後者は
        // **全行が同じ id を共有する**密なリストで、`and-apps_list`(id を1つも持たない密な
        // リスト)と同じ family の逆の極なので dense-list に入れる
        "ios-maps_transit_steps": "map", "ios-maps_transit_steps_expanded": "dense-list",
        // 2026-08-13 の監査(長い再利用リスト)で足した1枚。Android 設定の「すべてのアプリ」——
        // **40 要素すべてが identifier を持たず、scrollable を申告する要素も1つも無い**。
        // id を前提にした指標(前の木の id がどれだけ生き残るか)が**定義すらできない**盤面で、
        // 容器が無いので `ft_scroll_to` の逆走査(飛び越しの拾い直し)も走らない
        "and-apps_list": "dense-list",
        // 2026-08-13 の監査(フォーム / ログイン)で足した1枚。Android 設定の
        // 「ネットワークを追加」で WPA を選び、キーボードが立ったまま採った木。
        // **操作ボタン(保存/キャンセル)がツリーから丸ごと消えている** —— フォームが伸びて
        // `#buttonPanel` がキーボードとの間で 1080x12 に潰され、中身が公開されなくなった。
        // キーボード注記は「その下に触れる物は無い」と言うが、**消えたものは数えられない**
        "and-form_keyboard": "form",
        // 2026-08-13 の監査(モーダル / ダイアログ)で足した1枚。Android 設定のアプリ情報から
        // 開いた確認ダイアログ。**背景が a11y から丸ごと落ちる**(直前は 29 要素 → 6 要素)。
        // 画面の大半が木に無い形の陰性対照 —— **未表現率が極端でも、モーダルなら正常**
        "and-dialog_confirm": "dialog",
        // 2026-08-14 の監査(append-on-scroll の本物)で足した1枚。**iOS 実機**の SmartNews を
        // フィード先頭で採った木。この形の特徴は2つで、どちらも実アプリ固有:
        // ⑴ **行が画面幅いっぱい**(0,y 393xH)—— 自前 SUT の行はすべてインセットなので、
        //    全幅でだけ壊れる幾何(空打ちの終点が矩形から出られない)を代表していなかった
        // ⑵ **画面外の行 65 件が全部 (0,103) にクランプされて木に載る**(120 件中)。
        //    `compose-ios-ax-frame-clamp` と同型が UIKit の実アプリで出る。原点は同じでも
        //    大きさが違うので、`stackedRefs`(矩形の完全一致が3個以上)の死角の供給源
        "ios-news_feed": "feed",
        // 2026-08-14 の監査(全画面キャンバス)で足した1枚。**Android 実機**の Google カメラ。
        // 台帳が求めていた「a11y がほぼ空の面」の初の witness で、代表するのは2つ:
        // ⑴ **同一矩形 (0,288 1080x1440) に14要素**が積まれる(プレビューの重ね合わせ層)。
        //    ラベルを持つのは `viewfinder_frame` の1つだけなので `stackedRefs` は正しく黙る ——
        //    「無地のラッパーは数えない」と、原点クランプ判定の**陰性対照**
        // ⑵ 操作子が `staticText`(モード切替)で、器 `#bottom_bar` が z 上は手前・実体は透明という
        //    形。透明性は a11y から見えないので遮蔽の誤検知が出る(台帳に記録・規則は棄却済み)
        "and-camera_canvas": "canvas",
        // 自前 SUT(盤面が契約で固定されている対照)
        "sutec-calendar_day": "ec", "sutec-detail": "ec", "sutec-home": "ec",
        "sut-cmp_controls": "sut", "sut-cmp_home": "sut",
    ]

    static func family(_ fixture: String) -> String { archetypes[fixture] ?? "?" }

    // MARK: - 基準値(2026-08-12 実測 / 2026-08-13 にブラウザ2枚を追加して 34 画面)

    /// 発火の内訳(2026-08-12 実測 / コーパス 25 画面 = map 14・ec 3・settings 2・sut 2 +
    /// chat/keypad/media/webview 各1)。**アーキタイプを6枚足したときに判定が動いた** ——
    /// 19 枚(map 14・ec 3・sut 2)の時点では「maps でしか出ない」と見えていた5本のうち、
    /// **3本は他アーキタイプでも出た**:
    ///
    /// | 注記 | 19枚のとき | 25枚のとき |
    /// |---|---|---|
    /// | `unlabeledClickablesNote` | map のみ | map + **browser** (2026-08-13: settings は同一矩形の #id を見落とした誤検知と判明して除外) |
    /// | `keyboardCoverageNote` | map のみ | map + **chat** |
    /// | `scrollFrameCandidates` | map のみ | map + **chat** |
    /// | `ghostNote` / `truncationNote` | map のみ | **map のみのまま**(各1画面) |
    ///
    /// **「出ない」は「そのアプリがコーパスに無い」でしかないことがある**、の実例。
    /// 量の主因は `duplicateIDsNote`(15.1KB)と `ambiguousLabelsNote`(10.0KB)で変わらず、
    /// この2本は 5〜6/8 アーキタイプで発火する = 汎用の側。**削るなら文面であって対象ではない**
    static let baseline: [String: Coverage] = [
        // jma.go.jp から採った2本(2026-08-13)。**要素が全部ブラウザ chrome でページ本体が
        // 木に無い**形の witness(and-browser_jma_notree。unrepresentedScreenFraction 0.886)。
        // 陰性対照は and-browser_urlmenu(URL バーはあるが webView も無い画面。0.059)と
        // and-overflow(0.564 まで達するが URL バーが無いので黙る=browser 限定の理由)
        "missingPageContentNote": Coverage(fixtures: ["and-browser_jma_notree"], bytes: 458),

        // 2026-08-23: ブラウザ3画面が抜けた(7→4)。容器推定が scrollable 申告の祖先を優先するように
        // なり、旧規則が小さな link / staticText を容器と取り違えて立てていた ghost が消えたため
        // (SweepHarnessTests の同日の注記。残る4画面は容器の外へ出た行群の真陽性)
        // 2026-08-28: `and-browser_weather_weekly` が戻った(2026-08-23 以前と同じ)。容器推定で
        // 申告の祖先へ倒すのを「候補が小さすぎるとき」だけに絞った代償。理由と秤は
        // SweepHarnessTests の同フィクスチャの注記
        "ghostNote": Coverage(fixtures: ["and-browser_weather_weekly", "ios-maps_transit_steps", "ios-maps_transit_steps_expanded", "ios-news_feed", "ios-place_guides_scrolled"], bytes: 1999),
        // 横スクロール後の前後コピーが両方木に残る形の witness(ios-browser_jma_hscroll。
        // refs 72-81 vs 158-167 = 同じ行で x が定数200ptずれた10ペア)。他の全画面は最大3
        // (and-home)で、単純なキーだけの一致では別々の表の同名見出しに誤発火するため
        // y/x の幾何制約を必須にした(MCPServer.duplicateRegionNote の当該コメント参照)
        "duplicateRegionNote": Coverage(fixtures: ["ios-browser_jma_hscroll"], bytes: 391),
        "scrollFrameCandidates": Coverage(fixtures: ["and-form_keyboard", "and-place_expanded", "and-results", "ios-browser_startpage", "ios-maps_route_options", "ios-maps_station", "ios-maps_suggest_guides", "ios-maps_suggest_keyboard", "ios-maps_transit_steps", "ios-maps_transit_steps_expanded", "ios-messages_keyboard", "ios-news_feed", "ios-place_guides_scrolled"], bytes: 3168),
        // 2026-08-15 に J1順位表(両OS)を追加して +555 バイト。and-/ios- とも 120要素上限で
        // 38〜42件が脱落する高密度ページ(ios-browser_nationwide と同型)
        "truncationNote": Coverage(fixtures: ["and-browser_j1_standings", "ios-browser_j1_standings", "ios-browser_nationwide", "ios-browser_startpage", "ios-browser_yahoo_top", "ios-maps_station", "ios-news_feed"], bytes: 2149),
        // 取りこぼしのある Chrome の3枚(2026-08-13 に and-browser_weather_weekly を追加)で発火し、
        // 取りこぼしの無い iOS Safari の4枚(ios-browser_weektable / _weather_weekly 含む)では
        // 出ない(閾値の根拠は MCPServer.webViewGapNote のコメント)。browser 限定なのは
        // **webView を持つフィクスチャがブラウザ8枚しか無い**ためで、対象はアプリ内 WebView も含む。
        // and-browser_weather_weekly だけ**帯が2本**あり、複数形の文面になる(+577 バイトの主因)
        // 2026-08-15 に ios-browser_j1_standings を追加(+431 バイト)。これは
        // gridWithoutHeaderNote とは別の帯 —— 見出し行そのものは見つかっている(gridWithoutHeaderNote
        // は正しく黙る)一方、この画面には season セレクタ(「2026/27」)が iOS 側の a11y から
        // 丸ごと落ちている(Android 側の木には在る)ので、webViewGapNote は独立に真陽性で発火する
        "webViewGapNote": Coverage(fixtures: ["and-browser_weather", "and-browser_weather_weekly", "and-browser_weektable", "ios-browser_j1_standings"], bytes: 1965),
        // 値の格子はあるのに列見出しがツリーに無い形(2026-08-12・作業2の witness)。
        // 陰性対照は2枚 —— ios-browser_weektable(見出しがツリーにある)と、
        // 2026-08-13 に足した ios-browser_weather_weekly(**見出しが格子の最上行として
        // 取り込まれる**形。ここで初めて実アプリの誤検知が出た)。
        // 誤検知ゼロの根拠は GridWithoutHeaderNoteTests.testFiresOnlyOnTheAndroidWeektableWitness
        "gridWithoutHeaderNote": Coverage(fixtures: ["and-browser_weektable"], bytes: 511),
        "urlishLabelsNote": Coverage(fixtures: ["and-browser_weather", "and-browser_weather_weekly"], bytes: 590),
        // アドレス欄の値を名指しする。**既知 identifier だけで拾う**
        // (url_bar = Android Chrome / TabBarItemTitle = iOS Safari 通常時 /
        // URL = iOS Safari のアドレス欄タップ中 = ios-browser_startpage)。
        // 同じ webView を持つ and-browser_weather / and-browser_urlmenu は、捕った時点で
        // アドレス欄要素が無い(または値が空)ので黙る。**「値が URL らしい textField」の
        // フォールバックは置かない** —— メール欄・住所欄を誤って名乗る形がコーパスに無く、
        // 誤検知0の確認が効かないため(AddressBarNoteTests の当該テスト)
        // and-browser_error_page は 2026-08-15 に足した DNS エラーページ。**真陽性** ——
        // 読み込めなかった URL を名指しするのはこの画面でこそ要る情報。同日に J1順位表(両OS)も
        // 追加(+524 バイト。url_bar/TabBarItemTitle が jleague.jp を名乗る)
        "addressBarNote": Coverage(fixtures: ["and-browser_error_page", "and-browser_j1_standings", "and-browser_weektable", "ios-browser_j1_standings", "ios-browser_jma_hscroll", "ios-browser_nationwide", "ios-browser_startpage", "ios-browser_weather_weekly", "ios-browser_weektable", "ios-safari_article"], bytes: 2634),
        "unlabeledClickablesNote": Coverage(fixtures: ["and-apps_list", "and-browser_urlmenu", "and-directions_tabs", "and-home", "and-place", "and-place_expanded", "and-results", "ios-home", "ios-maps_route_options", "ios-news_feed"], bytes: 3845),
        // **格子は曖昧ラベルの塊**: 週間表の2枚が入って +2,049 バイト。
        // 同じ数値(`29/24`・`90%`)が行と列に何度も出るので、増分は形そのもの。
        // J1順位表(両OS。2026-08-15)も同型で +2,246 バイト —— 同じ勝点/試合数が縦横に並ぶ
        "ambiguousLabelsNote": Coverage(fixtures: ["and-apps_list", "and-browser_j1_standings", "and-browser_weather", "and-browser_weather_weekly", "and-browser_weektable", "and-camera_canvas", "and-home", "and-maps_suggest_ime", "and-place", "and-place_expanded", "and-results", "ios-browser_j1_standings", "ios-browser_jma_hscroll", "ios-browser_nationwide", "ios-browser_startpage", "ios-browser_weather_weekly", "ios-browser_weektable", "ios-browser_yahoo_top", "ios-home", "ios-maps_station", "ios-maps_suggest_keyboard", "ios-maps_transit_steps_expanded", "ios-messages_keyboard", "ios-news_feed", "ios-place", "ios-place_guides_scrolled", "ios-profile", "ios-safari_article", "ios-settings_root", "sut-cmp_controls", "sut-cmp_home", "sutec-detail", "sutec-home"], bytes: 21757),
        // 2026-08-15 に 16,940 → 16,984(+44)。**発火する画面は1枚も増えていない** ——
        // 増えたのは ios-place_guides_scrolled の `#PlaceCollectionCell` ×3 の**中身**で、
        // 40字超のラベルしか無い行に `*断片*` が書けるようになったぶん(以前は索引形 `~`)。
        // 索引形が stable な式に替わった = 増えたバイトはそのまま再現性の改善
        "duplicateIDsNote": Coverage(fixtures: ["and-dialer_keypad", "and-home", "and-overflow", "and-place_expanded", "and-results", "and-settings_root", "ios-browser_startpage", "ios-home", "ios-maps_route_options", "ios-maps_station", "ios-maps_suggest_guides", "ios-maps_suggest_keyboard", "ios-maps_transit_steps", "ios-maps_transit_steps_expanded", "ios-news_feed", "ios-photos_grid", "ios-place", "ios-place_guides_scrolled", "ios-profile", "ios-settings_root", "sutec-home"], bytes: 19851),
        // bytes 1169→1366→1170(2026-08-14・「chrome の部分木は覆われた側に数えない」修正):
        // fixtures 集合は不変(発火する画面は変わらない = 全画面「nothing tappable」か列挙のどちらか
        // では出続ける)。ios-maps_suggest_guides/ios-messages_keyboard は列挙(2件)から
        // 再び「nothing tappable」へ(その2件は chrome 自身の部分木だった)。
        // ios-maps_suggest_keyboard は列挙数が 30→20 に減るが、先頭8件(バイト数を左右する側)は
        // 変わらないので画面単体のバイト数は不変(SweepHarnessTests の baselines コメント参照)
        "keyboardCoverageNote": Coverage(fixtures: ["and-browser_urlmenu", "and-form_keyboard", "and-maps_suggest_ime", "ios-browser_startpage", "ios-maps_suggest_guides", "ios-maps_suggest_keyboard", "ios-messages_keyboard"], bytes: 1170),
        "truncatedLabelNote": Coverage(fixtures: ["and-browser_urlmenu", "and-browser_weather", "and-browser_weather_weekly", "and-place_expanded", "ios-browser_weektable", "ios-maps_transit_steps", "ios-maps_transit_steps_expanded", "ios-news_feed", "ios-photos_grid", "ios-place_guides_scrolled", "ios-safari_article", "ios-settings_root", "sutec-detail", "sutec-home"], bytes: 4315),
        // 2026-08-15 に J1順位表(Android)を足して初めて発火(それまで knownSilent)。
        // クラブ名「清水エスパルス」が下端で高さ6pxに切られた行 = SweepHarnessTests.baselines の
        // and-browser_j1_standings と同じ真陽性(sliver: 2)
        "sliverNote": Coverage(fixtures: ["and-browser_j1_standings"], bytes: 249),
    ]

    /// **コーパスでは構造上発火し得ないと確かめた注記**。ここに載せるには理由が要る ——
    /// 「出ないから」ではなく「なぜ出ないか」が言えること。**等号で照合する**ので、
    /// 理由を確かめていない新しい注記を足すと testEveryNoteFiresSomewhere が落ちる
    /// (この免除表が「死んだ注記の置き場」になるのを防ぐ)
    static let knownSilent: Set<String> = [
        // **既定が a11y になったので恒久的に黙る**(ユーザー決定)。
        // 実装は空文字を返すだけにしてある —— a11y から来ているのは正常で、言っても行動が
        // 変わらない(足りないときは missingPageContentNote が読み直しを促す)。
        // **目録から消すのは次のラウンド**(鍵の集合を変える操作は意識的に分ける)
        "browserA11yFallbackNote",
        // 全 19 枚とも `bulkExemptCount` の申告自体が無い(採取時のブリッジが出していない)。
        // 判定は `guard let count = snapshot.bulkExemptCount, count > 0` なので永久に出ない
        "bulkExemptNote",
        // **要素0の木はコーパスに置けない**: このコーパスは「実アプリの画面の形」を
        // 代表するためのもので、空の木はどの検知にも材料を与えず、アーキタイプにも属さない
        // (testEveryFixtureHasAnArchetype と testNoArchetypeDominatesTheCorpus が意味を失う)。
        // 判定そのものは `guard snapshot.elements.isEmpty` の1行なので、
        // EmptyTreeNoteTests の合成木で両方向を固定してある
        "emptyTreeNote",
    ]

    /// 1画面ぶんの注記の合計バイトの上限。**エージェントは木を読みに来ているのであって
    /// 注記を読みに来ているのではない** —— 上限を置かないと、監査のたびに1本ずつ足される注記が
    /// 木そのものを押しのける。2026-08-13 の実測は最大 2,684B(ios-maps_suggest_keyboard)。
    /// 超えたら「1本足す前に1本消す」を検討すること。
    ///
    /// **2026-08-14 に 3000 → 3200**(新しい最悪値 3,165B = `ios-news_feed`)。**注記は1本も
    /// 足していない** —— 実機のニュースフィードという新しいアーキタイプが、既存の7本を
    /// 同時に踏んだだけ(最大は ⚠️scroll-leftover の一覧 851B で、42 ref を畳んで並べている)。
    /// 消す候補を検分したが、この盤面ではどれも本命: leftover は「撃つと別物に当たる」本体、
    /// truncation は 35 件脱落、duplicateIDs/ambiguousLabels は `#crui_more_options_button` が
    /// 6個並ぶ形、scrollFrameCandidates は容器が2つある形。**上げるのは1回きりの記録**で、
    /// 次に超えたときはまた検分すること(黙って上げると現状追認装置になる)
    /// **2026-08-16 に 3200 → 3700**(新しい最悪値 3,621B = `ios-maps_transit_steps_expanded`)。
    /// **注記は1本も足していない** —— 「出力が非常に長い」と言われた画面そのものを
    /// 採ったら、既存の5本がこの量になった。検分した内訳(この画面の木は 5,658B なので
    /// **注記が木の 64%**。比較: `ios-news_feed` は 3,070B / 13,155B = 23%):
    ///
    /// | 注記 | バイト | 検分 |
    /// |---|---|---|
    /// | `duplicateIDsNote` | 1,810 | **正しい**。手順リストの全行が `#DetailButton`×10 `#PrimaryLabel`×8 … を共有し、素の `#id` では1つも選べない |
    /// | `ambiguousLabelsNote` | 880 | **正しい**。「4駅（12分）」「さらに表示」が行ごとに重複 |
    /// | `ghostNote` | 353 | **真陽性**(容器の外へ出た「出発 / 赤羽駅」の行群) |
    /// | `truncatedLabelNote` | 317 | 正しい(路線名が 40 字で切られる) |
    /// | `scrollFrameCandidates` | 261 | 正しい(容器が2つ) |
    ///
    /// **どれも誤りではない = 内容ではなく文面を削る以外に下げ道が無い**というのが、この
    /// 上げ幅そのものの意味。**削減が入ったら下げ直すこと**(この 3700 は現状追認ではなく、
    /// 未着手の課題「注記の量」の witness として置いてある)
    static let bytesPerScreenCeiling = 3700

    // MARK: - 測定

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/FleetestMCPTests/このファイル
            .deletingLastPathComponent()          // Tests/FleetestMCPTests
            .deletingLastPathComponent()          // Tests
            .appendingPathComponent("Fixtures/RealAppSnapshots")
    }

    private static func fixtureNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    private static func load(_ name: String) throws -> SnapshotResponse {
        let url = fixtureDirectory.appendingPathComponent(name + ".json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    /// 注記 × 画面の全数。**満額(abbreviated: false)で測る** —— 短縮はセッション内の2回目以降の
    /// 話で、ここが見たいのは「その注記が持つ最大のコスト」
    static func measure() throws -> (perNote: [String: Coverage], perFixture: [String: Int]) {
        var perNote: [String: Coverage] = [:]
        var perFixture: [String: Int] = [:]
        for name in try fixtureNames() {
            let snapshot = try load(name)
            // キャッシュは応答1回ぶん(SnapshotAnnotationCache の宣言参照)なので画面ごとに作る
            let input = NoteCatalog.Input(snapshot: snapshot)
            var total = 0
            for entry in NoteCatalog.snapshotNotes {
                let text = entry.render(input, false)
                guard !text.isEmpty else { continue }
                var coverage = perNote[entry.key] ?? Coverage(fixtures: [], bytes: 0)
                coverage.fixtures.append(name)
                coverage.bytes += text.utf8.count
                perNote[entry.key] = coverage
                total += text.utf8.count
            }
            perFixture[name] = total
        }
        return (perNote, perFixture)
    }

    // MARK: - 砦

    /// 発火の台帳が基準値どおりであること
    func testCoverageMatchesBaseline() throws {
        let measured = try Self.measure().perNote
        for key in Set(measured.keys).union(Self.baseline.keys).sorted() {
            let actual = measured[key]
            let expected = Self.baseline[key]
            XCTAssertEqual(actual, expected,
                           "\(key) の発火が変わった。**増えた分がどの画面で出たかを見ること** ——"
                           + " maps(ios-/and-)だけで増えたなら1アプリへの過適合の疑い。"
                           + " 採り直しは FT_NOTE_COVERAGE=1"
                           + " (実測: \(actual.map(\.description) ?? "発火なし")"
                           + " / 基準: \(expected.map(\.description) ?? "登録なし"))")
        }
    }

    /// **1画面も発火しない注記は、なぜ出ないかを言えるまで通さない**。目録に載っているだけで
    /// 一度も出ないなら、production で死んでいるか、コーパスがその形を代表していないかの
    /// どちらか —— どちらにせよ「効いている」証拠が無い。理由を確かめたものだけ
    /// `knownSilent` へ(**等号で照合する**ので、免除表が現状追認の置き場になることはない)
    func testEveryNoteFiresSomewhere() throws {
        let measured = try Self.measure().perNote
        let screens = try Self.fixtureNames().count
        let silent = Set(NoteCatalog.snapshotNotes.map(\.key).filter { measured[$0] == nil })
        XCTAssertEqual(silent, Self.knownSilent,
                       "固定コーパス \(screens) 画面での発火なしの集合が変わった"
                       + "(実測 \(silent.sorted()) / 既知 \(Self.knownSilent.sorted()))。"
                       + " 新しく黙ったなら消すか、その形を代表するフィクスチャを足すこと。"
                       + " 出るようになったなら knownSilent から外して基準値へ載せること")
    }

    /// **注記の量そのものの回帰ゲート**(bytesPerScreenCeiling の宣言参照)
    func testNoteBytesPerScreenStayUnderTheCeiling() throws {
        for (name, bytes) in try Self.measure().perFixture.sorted(by: { $0.key < $1.key }) {
            XCTAssertLessThanOrEqual(
                bytes, Self.bytesPerScreenCeiling,
                "\(name): 注記だけで \(bytes) バイト —— 木を押しのけていないか見ること"
                + "(1本足す前に1本消す)")
        }
    }

    /// 鍵の重複は短縮の状態を共有してしまう(片方を出すともう片方が黙る)
    func testCatalogKeysAreUnique() {
        let keys = NoteCatalog.snapshotNotes.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "NoteCatalog の鍵が重複している: \(keys)")
    }

    /// **1つのアーキタイプがコーパスを支配しないこと**。
    ///
    /// これは様式の好みではなく、**判定を守るための不変条件**: 偏ったコーパスは
    /// 「この注記は◯◯でしか出ない」という誤った結論を作る(19 枚・地図 14 の時点で
    /// 実際に5本のうち3本を取り違えた)。深く掘るほど地図が増え、**掘るほど判定が悪くなる**
    /// という逆向きの力が働くので、機械で止める。
    ///
    /// 上限 60%(2026-08-12 実測 = map 14/25 = 56%)。**地図の witness を足したくなったら、
    /// 他アーキタイプも一緒に足すこと** —— 上限を上げるのは最後の手段で、上げるなら
    /// 「なぜこのアーキタイプが多くてよいのか」を書くこと
    func testNoArchetypeDominatesTheCorpus() throws {
        let names = try Self.fixtureNames()
        let counts = Dictionary(grouping: names, by: Self.family).mapValues(\.count)
        for (archetype, count) in counts.sorted(by: { $0.key < $1.key }) {
            let percent = count * 100 / names.count
            XCTAssertLessThanOrEqual(
                percent, 60,
                "\(archetype) がコーパスの \(percent)%(\(count)/\(names.count))を占めている"
                + " —— 偏ったコーパスは「◯◯でしか出ない」という誤った判定を作る。"
                + " 他のアーキタイプを足すこと(WebView 主体・チャット・設定ツリー・"
                + "メディア・キャンバス系など)")
        }
    }

    /// **分類し忘れたフィクスチャを通さない**。分類が抜けると汎用性の内訳が静かに嘘になる
    /// (未分類の画面が `?` として集計から落ちるのではなく、どの族にも数えられない)
    func testEveryFixtureHasAnArchetype() throws {
        let names = try Self.fixtureNames()
        XCTAssertEqual(Set(names), Set(Self.archetypes.keys),
                       "フィクスチャと archetypes 表が食い違っている"
                       + "(表に無い: \(Set(names).subtracting(Self.archetypes.keys).sorted()) /"
                       + " 実体が無い: \(Set(Self.archetypes.keys).subtracting(names).sorted()))")
    }

    /// どの文脈にも載らない注記は目録にあるだけで出ない
    func testEveryNoteHasAContext() {
        for entry in NoteCatalog.snapshotNotes {
            XCTAssertFalse(entry.contexts.isEmpty, "\(entry.key) が どの応答にも載らない")
        }
    }

    /// **ft_scroll_to に載る注記の集合を等号で固定する**。
    ///
    /// なぜ等号か: ft_scroll_to は「swipe + snapshot の繰り返しの代わりに使え」と自ら勧める
    /// 経路なので、**警告が落ちる側が常用経路になる**。実測(Yahoo!天気の週間画面)では
    /// `link "13101"`(実際の描画は「千代田区」)と `"40％" ×3` を何の断りもなく返し、
    /// 同じ画面を ft_snapshot で撮り直して初めて両方が出た。
    /// **ここに並ぶのは「この一覧をそのまま報告してよいか / この行を指せるか」を言う注記**で、
    /// 外すと誤った出力に直結する。手数が増えるだけのもの(unlabeledClickablesNote)や
    /// スクロールでは変わらないもの(addressBarNote)は入れない ——
    /// 増やすときは Scripts/mcp-bench.sh の手数で決めること
    func testScrollToCarriesTheReadingIntegrityNotes() {
        XCTAssertEqual(Set(NoteCatalog.entries(for: .scrollTo).map(\.key)), [
            "emptyTreeNote", "missingPageContentNote", "ghostNote", "duplicateRegionNote",
            "truncationNote", "webViewGapNote", "gridWithoutHeaderNote", "urlishLabelsNote",
            "ambiguousLabelsNote", "duplicateIDsNote", "keyboardCoverageNote", "sliverNote",
            "truncatedLabelNote", "browserA11yFallbackNote",
        ])
    }

    // MARK: - 黙らせる指定(A/B)

    func testDisabledKeysParsing() {
        XCTAssertEqual(NoteCatalog.disabledKeys(from: nil), [])
        XCTAssertEqual(NoteCatalog.disabledKeys(from: "   "), [])
        XCTAssertEqual(NoteCatalog.disabledKeys(from: "sliverNote"), ["sliverNote"])
        XCTAssertEqual(NoteCatalog.disabledKeys(from: "sliverNote, ghostNote"),
                       ["sliverNote", "ghostNote"])
        XCTAssertEqual(NoteCatalog.disabledKeys(from: "sliverNote ghostNote"),
                       ["sliverNote", "ghostNote"])
        // all は目録の全鍵に展開する(将来足した注記も自動で入る)
        XCTAssertEqual(NoteCatalog.disabledKeys(from: "all"),
                       Set(NoteCatalog.snapshotNotes.map(\.key)))
        XCTAssertEqual(NoteCatalog.disabledKeys(from: "sliverNote,all"),
                       Set(NoteCatalog.snapshotNotes.map(\.key)))
    }

    /// **綴り違いを黙って無視しない**: 落ちていない注記を「落とした」と思って A/B を回すと、
    /// 「その注記は効かなかった」という誤った結論が出る
    func testUnknownDisabledKeysAreReported() {
        XCTAssertEqual(NoteCatalog.unknownDisabledKeys(["sliverNote"]), [])
        XCTAssertEqual(NoteCatalog.unknownDisabledKeys(["sliverNote", "sliverNotes", "zzz"]),
                       ["sliverNotes", "zzz"])
    }

    /// 黙らせた鍵が実際に応答から消えること(**陽性対照**)。
    /// **production の組み立て(`catalogNotes`)を通す** —— ここで判定を自前に書くと、
    /// 黙らせが効かなくなる変異を1つも検出できない(A/B が丸ごと無効になる型の事故)
    func testDisablingAKeyRemovesItFromTheAssembledNotes() throws {
        let snapshot = try Self.load("ios-maps_suggest_keyboard")
        let server = MCPServer(write: { _ in }, recordSnapshot: { _, _, _ in })
        let input = NoteCatalog.Input(snapshot: snapshot)
        let full = server.catalogNotes(input, context: .snapshot, disabled: [])
        XCTAssertFalse(full.isEmpty, "この画面でどの注記も出ない — 陽性対照にならない")

        // 1本ずつ落として、その本文だけが消えること
        for entry in NoteCatalog.entries(for: .snapshot) {
            let text = entry.render(input, false)
            guard !text.isEmpty else { continue }
            // **短縮を持ち越さないよう毎回新しいサーバで組む**(explainedNotes はセッション状態)
            let fresh = MCPServer(write: { _ in }, recordSnapshot: { _, _, _ in })
            let without = fresh.catalogNotes(input, context: .snapshot, disabled: [entry.key])
            XCTAssertFalse(without.contains(text),
                           "\(entry.key) を黙らせても本文が残る — 黙らせが効いていない")
            XCTAssertLessThan(without.utf8.count, full.utf8.count, "\(entry.key)")
        }

        // all は全部消える
        let allOff = MCPServer(write: { _ in }, recordSnapshot: { _, _, _ in })
            .catalogNotes(input, context: .snapshot,
                          disabled: NoteCatalog.disabledKeys(from: "all"))
        XCTAssertEqual(allOff, "")
    }

    /// **明細だけ畳む指定が production の組み立てに効くこと**(`FT_MCP_NOTES_BRIEF` の陽性対照)。
    /// 見るのは3つ: ⑴ 事実(ヘッダ)と群は残る ⑵ 明細(代替セレクタ)は消える
    /// ⑶ 既定(空集合)では1バイトも変わらない —— A/B の基準側が汚れていないこと
    func testBriefFoldsTheDetailButKeepsTheFact() throws {
        let snapshot = try Self.load("ios-maps_transit_steps_expanded")
        let brief = NoteCatalog.Input(snapshot: snapshot, brief: ["duplicateIDsNote"])
        let full = NoteCatalog.Input(snapshot: snapshot)
        guard let entry = NoteCatalog.snapshotNotes.first(where: { $0.key == "duplicateIDsNote" })
        else { return XCTFail("duplicateIDsNote が目録に無い") }
        let briefText = entry.render(brief, false)
        let fullText = entry.render(full, false)

        XCTAssertTrue(briefText.contains("#DetailButton ×10"),
                      "群と件数(=事実)は畳んだ側にも残ること: \(briefText)")
        XCTAssertTrue(briefText.contains("[11]"), "ref は残ること(叩く手段を奪わない)")
        XCTAssertFalse(briefText.contains(" >> .button["),
                       "明細(要素ごとの索引セレクタ)は畳まれること: \(briefText)")
        // 実測(2026-08-16): 1,810B → 912B(50.4%)。**既に畳まれている群には触らない**ので
        // 全部が消えるわけではない —— 残るのは compactGroupLine が既に1行にした群
        XCTAssertLessThan(briefText.utf8.count, fullText.utf8.count * 6 / 10,
                          "畳んでも 6 割を切らないなら、明細は出力量の主因ではない"
                          + "(実測 1810B → 912B)")

        // 既定は素通し(brief を渡さない Input は従来と1バイトも変わらない)
        XCTAssertEqual(NoteCatalog.Input(snapshot: snapshot, brief: []).brief, [])
        XCTAssertEqual(entry.render(NoteCatalog.Input(snapshot: snapshot, brief: []), false),
                       fullText)
    }

    /// 文脈の絞り込みが production の組み立てに効いていること(scrollTo は ft_snapshot より少ない)
    func testScrollToEmitsFewerNotesThanSnapshot() throws {
        let snapshot = try Self.load("ios-maps_suggest_keyboard")
        let input = NoteCatalog.Input(snapshot: snapshot)
        let onSnapshot = MCPServer(write: { _ in }, recordSnapshot: { _, _, _ in })
            .catalogNotes(input, context: .snapshot, disabled: [])
        let onScrollTo = MCPServer(write: { _ in }, recordSnapshot: { _, _, _ in })
            .catalogNotes(input, context: .scrollTo, disabled: [])
        XCTAssertLessThan(onScrollTo.utf8.count, onSnapshot.utf8.count)
    }

    // MARK: - 柵(目録の外に注記を足させない)

    /// **応答の組み立て側が注記関数を直に呼んでいないこと**。ここを通さずに足された注記は
    /// 発火が測れず、A/B でも黙らせられないまま増える(この台帳が意味を失う)
    func testSnapshotBodyEmitsOnlyCatalogNotes() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp")
        // 定義元(Hints)と唯一の呼び口(NoteCatalog)以外は直に呼んではいけない関数
        let forbidden = ["ghostNote(", "truncationNote(", "bulkExemptNote(",
                         "unlabeledClickablesNote(", "ambiguousLabelsNote(", "duplicateIDsNote(",
                         "keyboardCoverageNote(", "sliverNote(",
                         "SnapshotRenderer.truncatedLabelNote("]
        let exempt: Set<String> = ["MCPServer+Hints.swift", "NoteCatalog.swift"]
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter({ $0.hasSuffix(".swift") }).sorted() where !exempt.contains(file) {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                for symbol in forbidden where code.contains(symbol) {
                    XCTFail("\(file): 注記関数 \(symbol) を直に呼んでいる —— NoteCatalog へ足すこと"
                            + "(そうしないと発火が測れず、A/B でも黙らせられない): \(code)")
                }
            }
        }
    }

    // MARK: - 採り直し

    /// `FT_NOTE_COVERAGE=1` のときだけ動く。貼り付け用の基準値と、**由来の内訳**を出す
    func testPrintCoverage() throws {
        guard ProcessInfo.processInfo.environment["FT_NOTE_COVERAGE"] == "1" else { return }
        let (perNote, perFixture) = try Self.measure()
        let fixtures = try Self.fixtureNames()
        let families = Dictionary(grouping: fixtures, by: Self.family)
            .mapValues(\.count).sorted { $0.key < $1.key }
        print("CORPUS \(fixtures.count) screens — "
            + families.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        print("--- 貼り付け用(NoteCoverageTests.baseline) ---")
        for key in NoteCatalog.snapshotNotes.map(\.key) {
            guard let c = perNote[key] else { print("        // \(key): 発火なし"); continue }
            let list = c.fixtures.map { "\"\($0)\"" }.joined(separator: ", ")
            print("        \"\(key)\": Coverage(fixtures: [\(list)], bytes: \(c.bytes)),")
        }
        print("--- 汎用性(発火したアーキタイプ。1つだけなら過適合を疑う) ---")
        for key in NoteCatalog.snapshotNotes.map(\.key) {
            let c = perNote[key] ?? Coverage(fixtures: [], bytes: 0)
            let fired = Set(c.fixtures.map(Self.family)).sorted()
            let verdict = fired.isEmpty ? "← 死んでいる"
                : (fired.count == 1 ? "← \(fired[0]) でしか出ない" : "")
            print(String(format: "  %-26s %d/%d  %@  %@", (key as NSString).utf8String!,
                         fired.count, families.count, fired.joined(separator: ","), verdict))
        }
        print("--- 1画面あたりの注記バイト(上限 \(Self.bytesPerScreenCeiling)) ---")
        for (name, bytes) in perFixture.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-30s %5d", (name as NSString).utf8String!, bytes))
        }
    }
}
