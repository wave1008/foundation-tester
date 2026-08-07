// BridgeDTO.swift
// ホスト(macOS CLI)とXCUITestランナー(iOSシミュレータ)の間で共有するAPI型。
// このファイルは Runner/FTesterRunnerUITests ターゲットにも直接コンパイルされるため、
// Foundation 以外に依存してはならない。

import Foundation

public enum BridgeAPI {
    public static let defaultPort: UInt16 = 8123
    /// 1回のスナップショットで返す要素数の上限(4Kトークン対策の第一段)
    public static let maxSnapshotElements = 120
    /// ブリッジ HTTP API のプロトコルバージョン。エンドポイントやリクエスト/レスポンスの形を
    /// 変えたら必ず +1 する。/status で返され、旧ビルドのランナーの自動再起動判定に使う
    /// (nil = この定数導入前のビルド = 旧版扱い)。
    /// 4: 操作系が「対象アプリ未起動」に 503 を返すようになった(2026-07-28)。エンドポイントの
    /// 増減ではないが**版を上げる**: 旧ランナーが稼働中だと再利用され、XCUI の操作失敗で
    /// プロセスごと落ちる不具合(design.md 参照)を踏み続けるため、確実に入れ替える
    /// 5: snapshot が WKWebView を型 "WebView" として返すようになった(2026-07-29)。
    /// ホストはこの要素の有無で「XCUITest へ委譲する画面か」を判定する(WebViewDelegatingDriver)
    /// ため、旧ランナーが再利用されると**委譲が起きないまま緑になる**。確実に入れ替える
    /// 6: in-app が WKWebView の中身を DOM から読んで返すようになった(2026-07-29)。
    /// 旧 dylib が再利用されると中身が空のまま = XCUITest へ委譲され続け、
    /// 速度改善が入っていないのに緑になる
    /// 9: 無通信 TTL で自主終了するようになった(2026-07-30)。旧ランナーが再利用されると
    /// ゾンビ化防止が効かないまま残るため入れ替える
    /// 10: /status が起動元(ownerRepo/ownerPid)を自己申告するようになった(2026-07-30)。
    /// doctor の確定ゾンビ自動停止が申告に依存するため、確実に入れ替える
    /// 11: POST /clear(入力欄のクリア。DSL の clearInput)を追加(2026-07-30)。
    /// 旧ブリッジは 404 "not found:" を返し、ホスト側が「未対応」と誤判定し続けるため入れ替える
    /// 16: /clear が結果を読み返して確認する(**空に見えることを成功の根拠にしない**)ようになり、
    /// snapshot が focused を返すようになった(2026-07-30)。ホスト側の事後検証が focused に
    /// 依存するため、旧ブリッジの再利用を確実に断つ
    /// 20: POST /hidekeyboard を追加し、snapshot が keyboardShown を返すようになった(2026-07-30)。
    /// 旧ブリッジは 404 と nil を返し、keyboardIsShown が「状態不明」で失敗し続けるため入れ替える
    /// 23: XCUITest ランナーの /clear が「フォーカス欄が無い」「消し切れなかった」を
    /// **409 でなく 422** で返すようになった(2026-07-31)。旧ブリッジを再利用すると 409 のまま
    /// = ホストがセッション消失と誤断定して無用な activate を撃ち、誤った理由でステップを落とす
    /// 24: /clear が 2 周固定をやめ、空になるまで(deadline 付きで)叩くようになった(2026-07-31)。
    /// 旧ランナーが再利用されると高負荷での取りこぼしフレークが残ったままになる
    /// 25: in-app の整定が視覚効果パラメータ(scroll edge effect のぼかし)を「動いている」と
    /// 数えなくなった(2026-07-31)。旧 dylib が再利用されると launch 直後の 1〜2 アクションが
    /// 毎回 cap 2500ms に張り付いたままになる
    /// 26: in-app の swipe が Compose/Flutter で UIAccessibility の scroll アクション経由で
    /// 効くようになり、swipe を unsupportedActions に申告しなくなった(2026-07-31)。
    /// 旧 dylib が再利用されるとスクロールが全部 XCUITest へ回ったままになる
    /// 27: 整定を **cap で打ち切ったことを note で申告**するようになった(2026-07-31)。
    /// 旧ブリッジは黙るので「常態的に上限へ張り付いているのに緑」が見えないまま残る
    /// 28: Compose/Flutter でも **WebView 画面のスクロールを contentOffset で受けるようになった**
    /// (2026-08-01)。旧 dylib は 501 を返すので画面ごと XCUITest 委譲のままで、この短縮が効かない
    /// 29: XCUITest ランナーの /type が**送った打鍵数を完了の根拠にせず**、読み返して期待値に
    /// 届くまで足りないぶんを追送するようになった(2026-08-01)。旧ランナーが再利用されると
    /// 高負荷での打鍵取りこぼし(200 を返すのに値が空)が残ったままになる
    /// 30: in-app が interop(Compose/Flutter)ホストの WebView も DOM から読むようになり、
    /// snapshot が webViewPath: "dom-interop" を申告するようになった(2026-08-02)。旧 dylib は
    /// interop 配下を引き続き読めないと申告し続け、ホストが画面ごと XCUITest 委譲へ落とすため、
    /// テストは緑のまま速度改善だけが効かない
    /// 34: ブリッジ内の所要内訳ログ(tapTiming/settleTiming/reqTiming)を追加(2026-08-02)。
    /// **起動時にしか切り替わらない**ので /status の timingEnabled で状態を申告し、
    /// ホストは希望と食い違えば起動し直す。旧ブリッジを再利用すると「on にしたのに1行も出ない」
    /// = 計測できていないのに「待ちが無かった」と誤読する事故になる
    /// 35: SwipeRequest に用途つきのジェスチャ指定(distance/durationMs/fling)が入った(2026-08-02)。
    /// **読むのは Android ブリッジだけ**で iOS の挙動は変えていないが、DTO は iOS ブリッジの
    /// 入力でもあるため版を上げる(上げないと稼働中の旧ブリッジが再利用され続ける)
    /// 36: XCUITest ランナーの /swipe が SwipeRequest.velocity を受けるようになった(2026-08-02)。
    /// 旧ランナーが再利用されると既定速度のままで効かない
    /// 37: DragRequest.hold(終端ドウェル)を一時的に足した版(2026-08-02)。**実測で iOS では
    /// 慣性を止められないと分かったため 38 で撤去した**。37 のブリッジが稼働している環境を
    /// 確実に入れ替えるため、番号は再利用せず欠番にする
    /// 38: DragRequest.hold を撤去(2026-08-02)。wire 形式は 36 と同一だが、37 が稼働している
    /// 可能性があるので戻さず進める
    /// 39: SwipeRequest.path(スクロール領域を指定したときの実座標)を追加(2026-08-02)。
    /// 旧ブリッジは path を**黙って無視して全画面スワイプする** = 指定と違う領域が動くので
    /// 確実に入れ替える。in-app は座標を実行できないため 501 を返す(ホストが XCUITest へ回す)
    /// 40: in-app が path を「対象と移動量」として解釈するようになった(2026-08-02)。
    /// 39 の dylib は path つきを 501 で返すので、再利用されると領域指定のたびに XCUITest へ
    /// 委譲され続ける(**動くが遅いまま**でテストは緑 = 気付けない)
    /// 41: in-app の path 受理を **UIKit/SwiftUI(と WebView)に限定**(2026-08-02)。
    /// compose/flutter は領域を切り分けられず「指定と違う領域が動く」ため 501 に戻した。
    /// 40 の dylib が再利用されるとその誤動作が残る
    /// 43: snapshot が scrollable(スクロールできる容器か)を返すようになった(2026-08-02)。
    /// ホストは scrollFrame の指定が**スクロールできない領域を指していないか**の判定に使う。
    /// 旧ブリッジは返さないので判定が働かない(黙った空振りに気付けないまま)
    /// 42: in-app の整定が**スクロールの動き自体**を見るようになった(2026-08-02)。
    /// `setContentOffset(animated:)` は CALayer のアニメを伴わず旧実装をすり抜けるため、
    /// 「先頭へ」等の直後の snapshot が動く前のツリーを返し、**成功と記録されたまま
    /// 別の要素が掴まれていた**。旧 dylib が再利用されるとその誤動作が残る
    /// 44: POST /appstate(DSL の appIs)を追加(2026-08-03)。旧ブリッジは
    /// 404 "not found:" を返し続けるため入れ替える
    /// 45: XCUITest ランナーの GET /snapshot が XCUIElementTypeIcon(springboard のホーム画面
    /// アイコン)を含めるようになった(2026-08-03、tapAppIcon 用)。旧ランナーは identifier の
    /// 無いアイコンを黙って除外するため、tapAppIcon が「見つからない」で失敗し続ける
    /// 46: XCUITest ランナーの GET /snapshot が SnapshotResponse.offscreen(WebView 配下の
    /// 画面外ノード)を供給するようになった(2026-08-04)。Android は既に供給しており iOS だけ
    /// 欠けていたため offscreenJump/offscreenEdgeJump が一度も発火しなかった。旧ランナーは
    /// offscreen を返さない = 黙って無効のまま
    /// 47: POST /pinch(2本指ズーム)と POST /doubletap を追加(2026-08-04、マップ系アプリ用)。
    /// 旧ブリッジは 404 "not found:" を返すので、hybrid では XCUITest へ回って**動くが遅い**、
    /// xcuitest 単独では失敗し続ける。in-app は今もルートを持たない(= 404 でホストが回す)
    /// 48: /doubletap をランナー内の2打(間隔 60ms)に変えた版(2026-08-04)。**実測で
    /// `XCUICoordinate.tap()` が1打 335ms かかり、実際の間隔が約 400ms = 判定窓を外れて
    /// 単タップ2回になる**と分かったため 49 で撤去した。48 が稼働している環境を確実に
    /// 入れ替えるため番号は再利用せず欠番にする(37 と同じ扱い)
    /// 49: /doubletap を `XCUICoordinate.doubleTap()` へ戻した(2026-08-04)
    /// 50: **in-app ブリッジに /doubletap と /pinch を追加**(2026-08-04)。in-app は合成タッチの
    /// 間隔と指の距離を自分で決められるので、XCTest では成立しない組み合わせ(Compose の
    /// ダブルタップ)が通る。旧 dylib はルートを持たず 404 → ホストが XCUITest へ回すため、
    /// **入れ替えないと直った経路が使われないまま**になる
    /// 53: XCUITest ランナーの GET /snapshot が(a)**placeholder がそのまま来る value を空に正規化**し、
    /// (b)**同じ型・同じ位置で情報を足さない重複ノードを1つに畳む**ようになった(2026-08-06)。
    /// (a) が無いと iOS の WebView 入力欄だけ `value="<placeholder>"` になり `valueIs("")` が通らない
    /// (Android は空で返す = 経路で割れていた)。(b) が無いと UIKit の Switch・UIAlertController の
    /// ボタン・キーボードの Dictate が2つずつ出て、`.button[n]` の序数が見え方とずれる。
    /// **旧ランナーが再利用されるとどちらも直らないまま緑になる**
    /// 54: XCUITest ランナー・in-app の GET /snapshot が上限超過時の間引きを**先着順から
    /// 優先度順(BridgeSnapshotThinning)へ変えた**(2026-08-07)。同一 identifier を20件以上
    /// 持つ非スクロール・非操作の装飾群(地図ピン等)を最初に捨てるようになり、詳細シートの
    /// 中身のような本物のコンテンツが残るようになった。旧ランナー/dylib は先着順のままなので、
    /// 再利用されると枠を装飾に食われた画面で waitFor/scrollTo が見えない要素を探し続ける
    /// 55: in-app のエラー文を英語化(agent が読む面は英語 = CLI と同じ決定)+ pressEnter の
    /// 409 の助言を「先に欄へ tap/type」へ直した(2026-08-08。フォーカスが無いだけの場面で
    /// エンジン切替を勧めていた)。旧 dylib が再利用されると日本語文と誤誘導が残る
    /// 56: WebView DOM マージの上限超過を先着順から優先度順(mergedSlots)へ変えた
    /// (2026-08-08。密グリッドページで装飾セルが操作可能要素を全部押し出す実害を実測)。
    /// 旧 dylib が再利用されると DOM の濃い画面で送信ボタン等が木から消えたまま緑になる
    public static let bridgeProtocolVersion = 56

    /// 無通信 TTL の既定値(秒)。この時間リクエストが無いブリッジは自主終了する。
    /// 同期相手: AndroidRunner/src/com/example/ftbridge/BridgeInstrumentation.java の
    /// TTL_DEFAULT_SECONDS(AndroidBridgeVersionSyncTests が不一致を検出)
    public static let bridgeTTLSecondsDefault = 7200

    /// FT_BRIDGE_TTL(秒)の唯一の解釈者。0 = 無効(無期限)、未設定・空・非整数・負 = 既定値。
    /// Java 側 BridgeInstrumentation.parseTTL も同じ規則
    public static func resolvedBridgeTTLSeconds(_ raw: String?) -> Int {
        guard let raw, let value = Int(raw), value >= 0 else { return bridgeTTLSecondsDefault }
        return value
    }
}

/// GET /snapshot が maxSnapshotElements を超えたときに何を先に捨てるかの判定。
/// **in-app dylib と XCUITest ランナーの共通実装**(BridgeSourceSet 参照。両方コンパイルする)。
/// Android は Java で書けないため `AndroidRunner/.../SnapshotBuilder.java` の `priorityTier` に
/// 個別実装している —— **こちらを正とする。tier0〜2 を変えたら Java 側も直すこと**。
/// **tier3(bulk)は iOS だけ**: コーパス14本の実測で Android は1画面も発火しなかった
/// (Google マップを含む)ため移植していない。Android で bulk 群が出る画面を見つけたら、
/// ここを写して VERSION_CODE を上げる。
///
/// tier0(操作可能 or scrollable な容器) → tier1(ラベル/identifier を持つ) →
/// tier2(それ以外) → tier3(bulk。**新設**)の順に、tier3 から全部捨ててもまだ超過するなら
/// tier2、それでも超過するなら tier1 → tier0 と捨てる。同一 tier 内は preorder の後ろから捨てる
/// (先頭寄りの要素を優先して残す)。
///
/// bulk tier の根拠(コーパス14本・iOS/Android・2種の地図アプリ・4 SUT で確認):
/// 装飾ピン(同一 identifier ×90・scrollable な祖先なし・非操作)は地図画面の枠の大半を占めて
/// 本物のコンテンツ(リスト・詳細シート)を押し出す。**scrollable な祖先を持つ同一 identifier の
/// 群(長いリスト)は bulk にしない** —— 装飾90 対 正当な非スクロール群5(実測)の間に
/// 十分な余裕があるので閾値20で見分けられる。
public enum BridgeSnapshotThinning {

    /// 同一 identifier の出現数がこの数以上なら bulk tier の対象候補
    public static let bulkGroupMinimum = 20

    /// 操作可能とみなす正規化型名(ElementInfo.normalizedType 後の綴り = ElementInfo.init が
    /// 自動で適用するので、makeInfo が返す ElementInfo.type は既にこの形)。bulk tier からは
    /// 常に除外する
    public static let operableTypes: Set<String> = [
        "button", "cell", "textField", "secureTextField", "searchField", "switch",
        "checkBox", "link", "slider", "tab", "menuItem", "clickable", "textView",
    ]

    /// 間引き判定に要る、ElementInfo だけでは分からない情報。呼び出し側が生のツリー走査で作る
    public struct Candidate {
        public var info: ElementInfo
        /// scrollable な祖先(自分自身は含まない)を持つか。**必ず生のツリーの再帰で判定すること**
        /// —— スクロール容器はフィルタで snapshot に載らないのが普通(identifier が空だと
        /// isEligible/shouldInclude で落ちる)。emit 済みの配列から親を辿ると、容器が抜けた列で
        /// 正当なリストを bulk と誤判定する
        public var insideScrollable: Bool

        public init(info: ElementInfo, insideScrollable: Bool) {
            self.info = info
            self.insideScrollable = insideScrollable
        }
    }

    /// 超過時に残す候補の添字を、元の配列と同じ順序(preorder)で返す。max 以下ならそのまま全添字。
    /// **並べ替えない**: RefGuard.lineage が preorder+depth からツリーを復元し、ref の大小を
    /// z-order の代理に使う
    public static func indicesToKeep(_ candidates: [Candidate], max: Int) -> [Int] {
        let n = candidates.count
        guard n > max else { return Array(candidates.indices) }

        var identifierCounts: [String: Int] = [:]
        for candidate in candidates {
            guard let id = candidate.info.identifier, !id.isEmpty else { continue }
            identifierCounts[id, default: 0] += 1
        }

        var keep = [Bool](repeating: true, count: n)
        var remaining = n
        for currentTier in stride(from: 3, through: 0, by: -1) {
            guard remaining > max else { break }
            for index in stride(from: n - 1, through: 0, by: -1) {
                guard remaining > max else { break }
                guard keep[index], tier(candidates[index], identifierCounts: identifierCounts) == currentTier
                else { continue }
                keep[index] = false
                remaining -= 1
            }
        }
        return (0..<n).filter { keep[$0] }
    }

    /// WebView DOM マージ用の間引き。ネイティブ(間引き済み)の直後に各 webView コンテナの
    /// DOM 要素を差し込んだ合算列を作り、max 超過なら indicesToKeep と同じ優先度で捨てる。
    ///
    /// なぜ要るか(2026-08-08 に E2E-iOS の密グリッドページで実測): 従来の先着順カットは
    /// 装飾セル 115 個を残して**ページ上の操作可能要素(送信・入力欄・リンク・状態 echo)を
    /// 全部**押し出した —— iOS ネイティブ側が版54で直した形がマージ側に残っていた。
    ///
    /// insideScrollable は全件 true で渡す = **bulk tier はここでは効かせない**。
    /// ネイティブ側は1段目の間引きで bulk 適用済み・DOM ノードは identifier を持たないので
    /// bulk の対象になり得ず、マージ時点では生ツリーの scroll 祖先情報も失われている
    /// (false で渡すと、1段目を正当に生き残った同一 id 群を誤って bulk 扱いしかねない)
    public enum MergeSlot: Equatable, Sendable {
        /// base[i](ネイティブ要素)
        case base(Int)
        /// dom[container]![j](container = ネイティブ側 webView コンテナの ref)
        case dom(container: Int, index: Int)
    }

    public static func mergedSlots(base: [ElementInfo], dom: [Int: [ElementInfo]],
                                   max: Int) -> (kept: [MergeSlot], dropped: Int) {
        var slots: [MergeSlot] = []
        var candidates: [Candidate] = []
        for (i, info) in base.enumerated() {
            slots.append(.base(i))
            candidates.append(Candidate(info: info, insideScrollable: true))
            guard let elements = dom[info.ref] else { continue }
            for (j, element) in elements.enumerated() {
                slots.append(.dom(container: info.ref, index: j))
                candidates.append(Candidate(info: element, insideScrollable: true))
            }
        }
        let kept = indicesToKeep(candidates, max: max)
        return (kept.map { slots[$0] }, slots.count - kept.count)
    }

    /// 0(高優先・最後まで残す) … 3(bulk・最初に捨てる)
    static func tier(_ candidate: Candidate, identifierCounts: [String: Int]) -> Int {
        if isBulk(candidate, identifierCounts: identifierCounts) { return 3 }
        if operableTypes.contains(candidate.info.type) || candidate.info.scrollable == true { return 0 }
        let hasText = !(candidate.info.label ?? "").isEmpty || !(candidate.info.identifier ?? "").isEmpty
        return hasText ? 1 : 2
    }

    /// bulk 判定の3条件(すべて満たすときだけ true): 同一 identifier の群が bulkGroupMinimum 以上・
    /// scrollable な祖先を持たない・操作可能な型でない
    private static func isBulk(_ candidate: Candidate, identifierCounts: [String: Int]) -> Bool {
        guard !candidate.insideScrollable else { return false }
        guard let id = candidate.info.identifier, let count = identifierCounts[id],
              count >= bulkGroupMinimum else { return false }
        return !operableTypes.contains(candidate.info.type)
    }
}

/// CGRect の代わりに使うプラットフォーム非依存の矩形(エンコード形式を固定する)
public struct FTRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

public struct StatusResponse: Codable, Sendable {
    public var ready: Bool
    public var device: String
    public var osVersion: String
    public var sessionBundleID: String?
    /// 駆動エンジン種別("inapp" / "xcuitest")。同一シミュレータ(UDID)に複数ブリッジが
    /// 共存するハイブリッド時、ホストがどのブリッジかを /status で区別するために使う。
    /// 旧ブリッジは返さない → decodeIfPresent で nil 許容(=不明)。
    public var engine: String?
    /// BridgeAPI.bridgeProtocolVersion。旧ブリッジは返さない → nil 許容(=旧版扱い)。
    public var protocolVersion: Int?
    /// UIApplication.applicationState の文字列化("active"/"inactive"/"background")。
    /// inapp 専用診断(背面 suspend でハングしていないかの申告)。xcuitest ブリッジは返さない → nil 許容。
    public var applicationState: String?
    /// inapp ブリッジが自己申告する UI フレームワーク("compose"/"uikit")。判定は InAppBridge の
    /// compose-resources 実在チェック。xcuitest/Android ブリッジは返さない → nil 許容。
    public var uiFramework: String?
    /// Android ブリッジ APK の versionCode(BridgeRouter.java handleStatus)。稼働中の旧ブリッジを
    /// probe 時に検知して自動更新するために使う。iOS ブリッジ・旧 Android ブリッジは返さない → nil 許容。
    public var bridgeVersionCode: Int?
    /// xcuitest ランナーが高速入力(quiescence スキップ)swizzle の導入に成功したか(FastInput.swift)。
    /// 旧ランナー・他ブリッジは返さない → nil 許容(=非対応)
    public var fastInputAvailable: Bool?
    /// このブリッジが**この対象アプリでは実行できない**アクション名(FlowStep.action と同じ語:
    /// "swipe" / "press" 等)。ホストはこれを見て代替ドライバへ回す/明示的に失敗させる。
    /// 「compose なら swipe 不可」のような知識をホストへ散らかさず、事情を知っている
    /// ブリッジ側に集約するための申告。返さない実装は nil(=制約なしとみなす)。
    public var unsupportedActions: [String]?
    /// 起動元リポジトリのルートパス(iOS=FT_OWNER_REPO 環境変数 / Android=-e owner)。
    /// doctor の刈り取り判定が依存: パスが実在しなければ確定ゾンビとして自動停止できる。
    /// 旧ブリッジは返さない → nil 許容(=起動元不明・報告のみ)
    public var ownerRepo: String?
    /// ランナープロセスの pid(iOS のみ。ホスト上のプロセスなので doctor が直接停止できる)。
    /// Android は device 内 pid になり意味が違うため返さない
    public var ownerPid: Int?
    /// このリクエストの直前の無通信秒数(「いつから放置されていたか」の診断用)
    public var idleSeconds: Double?
    /// 所要内訳ログ(tapTiming/settleTiming/reqTiming)が有効な状態で起動しているか。
    /// **起動時にしか切り替わらない**ので、ホストは希望状態と食い違うときブリッジを起動し直す
    /// (Android: AndroidBridge.startBridge)。返さない実装は nil(=off とみなす)
    public var timingEnabled: Bool?

    public init(ready: Bool, device: String, osVersion: String, sessionBundleID: String?,
                engine: String? = nil, protocolVersion: Int? = nil, applicationState: String? = nil,
                uiFramework: String? = nil, bridgeVersionCode: Int? = nil,
                fastInputAvailable: Bool? = nil, unsupportedActions: [String]? = nil,
                ownerRepo: String? = nil, ownerPid: Int? = nil, idleSeconds: Double? = nil,
                timingEnabled: Bool? = nil) {
        self.ready = ready
        self.device = device
        self.osVersion = osVersion
        self.sessionBundleID = sessionBundleID
        self.engine = engine
        self.protocolVersion = protocolVersion
        self.applicationState = applicationState
        self.uiFramework = uiFramework
        self.bridgeVersionCode = bridgeVersionCode
        self.fastInputAvailable = fastInputAvailable
        self.unsupportedActions = unsupportedActions
        self.ownerRepo = ownerRepo
        self.ownerPid = ownerPid
        self.idleSeconds = idleSeconds
        self.timingEnabled = timingEnabled
    }
}

public struct LaunchRequest: Codable {
    public var bundleID: String
    /// true なら XCUIApplication.activate()(起動中は状態保持で前面化、未起動なら起動)。
    /// nil/false は従来どおり launch(再起動)。旧ランナーは本フィールドを無視して launch する。
    public var activate: Bool?
    /// true ならプロキシ接続のみ(XCUIApplication を生成・保持するだけで launch/activate を呼ばない。
    /// simctl で起動済みのアプリに使う=FastLaunchDriver)。activate より優先。
    /// 旧ランナーは無視して launch する(TapRequest.fast と同じ互換方針で版は据え置き)
    public var attachOnly: Bool?
    public init(bundleID: String, activate: Bool? = nil, attachOnly: Bool? = nil) {
        self.bundleID = bundleID
        self.activate = activate
        self.attachOnly = attachOnly
    }
}

/// アクセシビリティツリーの1要素(ランナー側でフィルタ済み)
public struct ElementInfo: Codable, Sendable {
    /// set-of-mark 参照番号(スナップショット毎に振り直す)
    public var ref: Int
    /// 型名。**ホスト側では常に先頭小文字**(`button` / `staticText`)。
    /// ブリッジは歴史的経緯で `Button` を送ってくるので、デコード時に normalizedType で畳む。
    /// セレクタ記法 `.button` と、スナップショット表示・生成コードの型名を一致させるための唯一の変換点
    /// (3ブリッジの wire 形式は変えない = APK versionCode もプロトコル版も上げなくてよい)。
    public var type: String
    public var identifier: String?
    public var label: String?
    public var value: String?
    public var placeholder: String?
    public var enabled: Bool
    /// チェック状態(true のときだけ送る = 省略は「オフ、または状態を持たない要素」)。
    /// 取得元は iOS=`isSelected`(Compose iOS は Switch の value を出さないためこちらが唯一の経路)/
    /// Android=`AccessibilityNodeInfo.isChecked`。isChecked / isNotChecked が唯一の読み手
    public var checked: Bool?
    public var frame: FTRect
    public var depth: Int
    /// **DOM から読んだ Web コンテンツか**(true のときだけ送る)。in-app ブリッジが WKWebView の
    /// 中身を読めたときに立てる。ホストは「in-app で中身が読めているか」をこれで判定する
    /// (幾何で判定すると WebView と同じ矩形を持つ interop 容器を中身と誤認する。2026-07-29 実害)
    public var web: Bool?
    /// **スクロールできる容器か**(true のときだけ送る = checked/web と同じ省略規約)。
    /// 取得元: Android=`AccessibilityNodeInfo.isScrollable` / iOS xcuitest=要素の型
    /// (scrollView / table / collectionView)/ iOS in-app=`UIScrollView` かどうか。
    /// **Compose/Flutter の in-app では申告できない**(自前描画で UIScrollView を持たず、
    /// AX の scroll 可否は**呼ぶと実際にスクロールしてしまう**ので非破壊に判定できない)。
    /// だから「false = スクロールできない」と読んではいけない —— 使ってよいのは
    /// **true を見つけたときだけ**(scrollFrame の指定が空振りかの判定に使う)
    public var scrollable: Bool?
    /// **入力フォーカスを持つか**(true のときだけ送る = checked/web と同じ省略規約)。
    /// clearInput(ref なし)の事後検証(StepExecutor)が、クリア前後のスナップショットで
    /// 同一要素を突き合わせるための唯一の手がかり。取得元: iOS xcuitest=`hasKeyboardFocus` /
    /// iOS in-app=`isFirstResponder` / Android=`AccessibilityNodeInfo.isFocused`
    public var focused: Bool?
    /// **塗り順**(0 起点の通し番号。大きいほど手前)。nil = ブリッジが申告しない
    /// (iOS の XCUITest / in-app には描画順を読む API が無い)。
    ///
    /// **preorder は描画順ではない**ので、遮蔽の判定にツリー順を代理で使うと裏返る ——
    /// Google マップは地図の FAB をシートより後に出すが、描画はシートが手前で、
    /// 「シートの裏の要素」を無警告でタップして別アプリを起動していた(2026-08-07 実測)。
    ///
    /// **ホストでは合成できないのでブリッジが1本の整数にして送る**: 出力ツリーは中間ノードを
    /// 間引くため、2要素の共通祖先が木に残っておらず、段ごとの `getDrawingOrder` を
    /// 突き合わせられない(実測: `#mylocation_button` の祖先鎖は3段で、シート側と1つも共有が無い)。
    /// 生成は SnapshotBuilder.assignPaintOrder。**nil のときは ref 順へ落ちる**
    public var z: Int?

    /// スライダー/プログレスの**取り得る範囲**(`"0-100"`)。nil = 範囲を持たない要素、
    /// またはブリッジが申告しない。現在値は `value` に入る。
    ///
    /// **パーセントへ正規化しない**のが決定(2026-08-07): 0..10 のスライダーで current=3 を
    /// "30%" と言うのは、生値を読みたい側には嘘に近い。範囲を別に添えて割合は読み手に任せる。
    /// 取得元: Android=`AccessibilityNodeInfo.getRangeInfo`。
    /// **iOS はまだ出さない**(XCUIElement.value が `"50%"` を返すので value 側だけは読める)
    public var range: String?

    public init(ref: Int, type: String, identifier: String?, label: String?, value: String?,
                placeholder: String?, enabled: Bool, frame: FTRect, depth: Int,
                checked: Bool? = nil, web: Bool? = nil, focused: Bool? = nil,
                scrollable: Bool? = nil, z: Int? = nil, range: String? = nil) {
        self.range = range
        self.scrollable = scrollable
        self.z = z
        self.ref = ref
        self.type = Self.normalizedType(type)
        self.identifier = identifier
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.enabled = enabled
        self.checked = checked
        self.frame = frame
        self.depth = depth
        self.web = web
        self.focused = focused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(Int.self, forKey: .ref)
        type = Self.normalizedType(try container.decode(String.self, forKey: .type))
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        checked = try container.decodeIfPresent(Bool.self, forKey: .checked)
        frame = try container.decode(FTRect.self, forKey: .frame)
        depth = try container.decode(Int.self, forKey: .depth)
        web = try container.decodeIfPresent(Bool.self, forKey: .web)
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused)
        scrollable = try container.decodeIfPresent(Bool.self, forKey: .scrollable)
        z = try container.decodeIfPresent(Int.self, forKey: .z)
        range = try container.decodeIfPresent(String.self, forKey: .range)
    }

    /// 先頭 1 文字だけ小文字化する(`StaticText` → `staticText`)。冪等なので二重適用しても安全
    public static func normalizedType(_ type: String) -> String {
        guard let first = type.first, first.isUppercase else { return type }
        return first.lowercased() + type.dropFirst()
    }
}

public struct SnapshotResponse: Codable, Sendable {
    public var sessionBundleID: String?
    public var screen: FTRect
    public var elements: [ElementInfo]
    /// 上限超過で切り捨てた要素数(FMへのプロンプトにも明記する)
    public var truncatedCount: Int
    /// このスナップショットで**取りこぼしがある**ことの申告(例: クロスオリジン iframe は
    /// main frame の JS から読めない)。旧ブリッジは返さない → nil 許容。
    /// 黙って要素ゼロにしないための経路で、ホストは lastActionNote として記録に載せる
    public var note: String?
    /// WebView 内の**画面外**ノード(スクロールヒント)。frame はクランプ前の実座標
    /// (Chromium は全ドキュメントをツリーに載せる。Android ブリッジ v18 以降のみ・他は nil)。
    /// スクロール探索が「目的の要素がどの方向・何 px 先か」を知り、盲目的スワイプを
    /// 長距離ドラッグへ置き換えるために使う(StepExecutor.offscreenJump)。
    /// **要素解決には決して使わない**(見えない要素へ exist/tap が当たる)。ref は全て 0
    public var offscreen: [ElementInfo]?
    /// WebView の中身を**どの経路で読んだか**の申告。`"dom"` = in-app が DOM を JS で走査 /
    /// `"dom-interop"` = DOM は読めたが interop(Compose/Flutter)ホスト配下 = 操作はホスト側
    /// (WebViewDelegatingDriver)が座標へ解決して XCUITest の実タッチへ回す /
    /// `"delegated"` = XCUITest へ画面ごと委譲(ホスト側の WebViewDelegatingDriver が入れる)。
    /// **要素の形から推測してはいけない**: Android は webView 型を出すが web フラグを持たないため、
    /// 推測すると「XCUITest へ委譲」と名乗って Android のデバッグを誤誘導する(2026-07-29 実害)。
    /// 経路を知っているのは snapshot を返した本人だけなので、そこに申告させる。
    /// 追加 optional フィールドのみなので bridgeProtocolVersion は据え置き(TapRequest.fast と同じ方針。
    /// 旧ブリッジは返さず nil = 申告なし = 注記も出ない、で安全に縮退する)
    public var webViewPath: String?
    /// **ソフトキーボードが表示中か**(true のときだけ送る = checked/web/focused と同じ省略規約。
    /// 省略は「非表示、または不明」)。要素単位ではなくスナップショット全体の状態。
    /// 取得元は iOS xcuitest=ツリー走査中に `.keyboard` ノードを見たか / iOS in-app=同走査中に
    /// `.keyboardKey` ノードを見たか / Android=オンデバイスのブリッジではなくホスト側の
    /// `AndroidDriver.snapshot()` が `dumpsys window windows` から算出(dumpsys の固定費を避けるため
    /// `captureKeyboardStateOnNextSnapshot()` で立てた回だけ。それ以外は nil)。
    public var keyboardShown: Bool?

    public init(sessionBundleID: String?, screen: FTRect, elements: [ElementInfo],
                truncatedCount: Int, note: String? = nil, webViewPath: String? = nil,
                offscreen: [ElementInfo]? = nil, keyboardShown: Bool? = nil) {
        self.sessionBundleID = sessionBundleID
        self.screen = screen
        self.elements = elements
        self.truncatedCount = truncatedCount
        self.note = note
        self.webViewPath = webViewPath
        self.offscreen = offscreen
        self.keyboardShown = keyboardShown
    }
}

public struct TapRequest: Codable {
    public var ref: Int?
    public var x: Double?
    public var y: Double?
    /// true = quiescence 待ちスキップの高速入力(PoC・FastInput.swift)。省略可能な追加
    /// フィールドのみのため bridgeProtocolVersion は据え置き(旧ランナーは無視して通常タップ・
    /// 旧ホストは未指定。bump すると稼働中の旧ホスト常駐プロセスが新ランナーを stale 判定して
    /// 再起動ループに入るため、追加フィールドでは上げない)
    public var fast: Bool?
    public init(ref: Int? = nil, x: Double? = nil, y: Double? = nil, fast: Bool? = nil) {
        self.ref = ref
        self.x = x
        self.y = y
        self.fast = fast
    }
}

public struct DragRequest: Codable {
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double
    /// 押下から移動開始までの静止時間(秒)。nil は最小値(0.05)扱い
    public var press: Double?
    /// 移動開始から離すまでの時間(秒)。nil は既定速度。
    /// **終端ドウェル(`thenHoldForDuration`)のフィールドは持たない** —— 2026-08-02 に実測して
    /// **iOS では慣性を止められない**ことが分かったため(v1500 + hold 0.2s で 2.85→2.82 倍。
    /// 所要だけ +200ms)。XCUITest の hold は指を保持するだけでイベントを出さず、
    /// `UIPanGestureRecognizer` の速度計算が更新されない。詳細は docs/performance-tuning.md §6
    public var duration: Double?
    public init(fromX: Double, fromY: Double, toX: Double, toY: Double,
                press: Double? = nil, duration: Double? = nil) {
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.press = press
        self.duration = duration
    }
}

public struct TypeRequest: Codable {
    public var ref: Int?
    public var text: String
    public init(ref: Int? = nil, text: String) {
        self.ref = ref
        self.text = text
    }
}

/// POST /clear(入力欄のクリア。DSL の clearInput)。3ブリッジ共通。
/// ref あり = その要素へフォーカスを立ててからクリア(/type の ref 経路と同じ点解決)。
/// ref なし = フォーカス中の入力欄をクリア。対象が無ければ 409(/type の 409 と同じ扱いで
/// ホストは typeDriver へフォールバックする)
public struct ClearRequest: Codable {
    public var ref: Int?
    public init(ref: Int? = nil) {
        self.ref = ref
    }
}

/// swipe の**用途**。同じ「上へ払う」でも要求される性質が違うので、ホストが用途を伝えて
/// ブリッジ側がジェスチャを選ぶ。
/// - `gesture`: DSL の `swipe`。**ジェスチャ自体が目的**(向きの検出をアプリに見せたい)
/// - `search`: `scrollTo` / `scrollDown` 等。**飛距離がビューポート高を超えると要素を飛び越す**
///   ので、1回の移動量を欲張らない
/// - `edge`: `scrollToEdge`。行き過ぎても無害なので**最速で端まで**送ってよい
public enum FTSwipeIntent: String, Codable, CaseIterable {
    case gesture, search, edge
}

/// **ジェスチャの向き**(指の動き)。ブリッジの /swipe はこれを受ける
public enum FTSwipeDirection: String, Codable, CaseIterable {
    case up, down, left, right
}

/// **スクロールの向き**(コンテンツ基準。標準用語どおり `.down` = 下に読み進める)。
/// Shirates の `ScrollDirection` と同じ構成(`None` は ftester では Optional が担うため持たない)。
/// **指の動きとは逆**なので、ジェスチャへの写像はここに1箇所だけ置く
public enum FTScrollDirection: String, Codable, CaseIterable, Sendable {
    case down, up, right, left

    /// このスクロールを起こすための指の動き(`.down` に読み進めるには指を上へ動かす)
    public var swipe: FTSwipeDirection {
        switch self {
        case .down: return .up
        case .up: return .down
        case .right: return .left
        case .left: return .right
        }
    }
}

/// スワイプの実座標(snapshot の screen と同じ座標系。iOS = pt / Android = px)。
/// 作るのはホストの `ScrollGeometry`(FTCore)だが、**型はここに置く** ——
/// このファイルはランナーのターゲットにも直接コンパイルされるため
public struct FTSwipePath: Codable, Equatable, Sendable {
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double

    public init(fromX: Double, fromY: Double, toX: Double, toY: Double) {
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
    }

    /// 始点から終点までの距離(velocity の算出に使う。縦横どちらかしか動かさないので単純和でよい)
    public var distance: Double { (toX - fromX).magnitude + (toY - fromY).magnitude }
}

public struct SwipeRequest: Codable {
    public var direction: FTSwipeDirection
    /// TapRequest.fast と同じ(互換性の注記もそちらを参照)
    public var fast: Bool?
    /// **スクロールが目的**の swipe か(scrollTo / scrollToEdge / scrollDown が立てる)。
    /// DSL の `swipe` はジェスチャそのものが目的なので立てない。
    ///
    /// in-app の Compose/Flutter だけがこれを見る: スクロールは UIAccessibility の scroll
    /// アクションで代行できるが、**ジェスチャ目的の swipe を同じ経路へ流すと、画面内の
    /// スクロール可能な親が受理してしまい、ジェスチャ検出パッドに届かないまま 200 を返す**
    /// (2026-07-31 実測: E2E-Flutter のジェスチャ画面が黙って空振りした)。
    /// 旧ブリッジは無視して従来動作(TapRequest.fast と同じ互換方針で版は据え置かない —
    /// 挙動が変わるので handleSwipe 側の変更とセットで上げる)
    public var scroll: Bool?
    /// 指の移動距離(画面比)。**Android ブリッジだけが読む**。未指定はブリッジの軸別既定
    /// (縦 0.4・横 0.6 = 従来の固定座標と同一)。ホストは送らない(計測・将来の override 用の口。
    /// 広げると始点がスクロール領域の外に出る罠は BridgeClient.edgeSwipeDurationMs のコメント)
    public var distance: Double?
    /// ストローク時間(ms)。短いほど離す瞬間の速度が上がりフリングが伸びる
    public var durationMs: Int?
    /// ACTION_UP の eventTime を MOVE と同じ合成時刻にするか。**Android の View/Compose では
    /// これが false(= 実時計)だとフリングが出ない**(実測: 276px → 1,156px)。
    /// 既定 false = 従来動作。Flutter は影響を受けない(独自の速度計算)
    public var fling: Bool?
    /// スワイプ速度(points/sec)。**XCUITest ランナーだけが読む**(`XCUIGestureVelocity`)。
    /// nil = `swipeUp()` 等の既定速度。Android は距離とストローク時間で速度を決めるので読まない
    public var velocity: Double?
    /// **スクロール領域を指定したときの実座標**(snapshot の screen と同じ座標系)。
    /// ホストが `ScrollGeometry` で計算して送る。**nil = 従来の全画面固定**(ブリッジ側の
    /// 軸別既定で計算する)。両 OS のブリッジがこれを読む —— 経路を分けると
    /// 「どこをスクロールするか」の決定がエンジンごとに割れるため。
    /// **in-app ブリッジは座標を撃たずに「対象と移動量」として読む**: 始点は必ず対象領域の
    /// 内側にある(ホストがマージンを内側に取る)ので動かすスクロールビュー/AX 要素の特定に使い、
    /// 始点と終点の差を contentOffset の移動量に使う。これで in-app でもマージンが効く
    public var path: FTSwipePath?
    public init(direction: FTSwipeDirection, fast: Bool? = nil, scroll: Bool? = nil,
                distance: Double? = nil, durationMs: Int? = nil, fling: Bool? = nil,
                velocity: Double? = nil, path: FTSwipePath? = nil) {
        self.path = path
        self.direction = direction
        self.fast = fast
        self.scroll = scroll
        self.distance = distance
        self.durationMs = durationMs
        self.fling = fling
        self.velocity = velocity
    }
}

/// POST /pinch(2本指のズーム。DSL の pinchOut / pinchIn)。
/// **2つの表現を同時に運ぶ**のは、対象の指定方法が OS で原理的に違うため:
/// - Android(`InputInjector.pinch`)は座標を合成できるので `frame` の中心を使う
/// - XCUITest は座標を指定した多点ジェスチャを持たず `XCUIElement.pinch(withScale:velocity:)`
///   しかない = **要素を掴むしかない**ので `identifier` で引く(見つからなければアプリ全体)
///
/// ホストは対象を1回解決して両方を埋める(同期相手: StepExecutor の "pinch" アクション /
/// Runner の handlePinch / AndroidRunner BridgeRouter.handlePinch)
public struct PinchRequest: Codable {
    /// 拡大率。> 1 = 拡大(指を開く) / 0 < scale < 1 = 縮小(指を閉じる)。
    /// **XCUITest は scale と velocity の符号が食い違うと例外を投げる**ので、velocity は
    /// ランナー側が scale から導出する(ホストからは送らない)
    public var scale: Double
    /// ジェスチャの所要時間(秒)。Android のストローク時間・iOS の velocity 算出に使う
    public var durationSeconds: Double?
    /// 対象領域(snapshot の screen と同じ座標系)。nil = 画面全体。**Android だけが読む**
    public var frame: FTRect?
    /// 対象の accessibility identifier。nil / 解決不能 = アプリ全体。**XCUITest だけが読む**
    public var identifier: String?
    public init(scale: Double, durationSeconds: Double? = nil,
                frame: FTRect? = nil, identifier: String? = nil) {
        self.scale = scale
        self.durationSeconds = durationSeconds
        self.frame = frame
        self.identifier = identifier
    }
}

public struct PressRequest: Codable {
    public var ref: Int?
    public var x: Double?
    public var y: Double?
    public var duration: Double
    /// TapRequest.fast と同じ(互換性の注記もそちらを参照)
    public var fast: Bool?
    public init(ref: Int? = nil, x: Double? = nil, y: Double? = nil, duration: Double,
                fast: Bool? = nil) {
        self.ref = ref
        self.x = x
        self.y = y
        self.duration = duration
        self.fast = fast
    }
}

public struct OKResponse: Codable {
    public var ok: Bool
    /// 通常と違う経路を通ったときの短い説明(既定 nil)。失敗ではなく観測用(例: InAppBridge.handleTap の
    /// activate 不発→合成タッチ)。throw にしない代わりに StepExecutor.driverFallback へ載せて可視化する。
    public var note: String?
    public init(ok: Bool = true, note: String? = nil) {
        self.ok = ok
        self.note = note
    }
}

/// POST /appstate(DSL の appIs)。読み取り専用でセッション不要
/// (両ブリッジとも requireApp() を経由しない。同期相手: Runner/BridgeRouter.swift handleAppState /
/// InAppBridge/Sources/InAppBridge.swift handleAppState)。
public struct AppStateRequest: Codable {
    public var bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }
}

public struct AppStateResponse: Codable {
    public var foreground: Bool
    public init(foreground: Bool) { self.foreground = foreground }
}

public struct ErrorResponse: Codable {
    public var error: String
    public init(error: String) { self.error = error }
}
