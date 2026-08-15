// MCPServer+Hints.swift
// 木に添える注記・ヒント(ghost・類似ラベル・遮蔽・切り詰め等)。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// 半開きシートのグラバー。**名前で特定できるときだけ**返す(当てずっぽうのドラッグは
    /// 地図やリストを勝手に動かすので、確信が無いなら何もしないほうが良い)。
    /// UIKit/SwiftUI のシートは `Card grabber` のような id/ラベルを出す(実測: Apple マップ)。
    ///
    /// 下半分に居るものだけを対象にする —— 既に上まで開いているグラバーを更に引いても
    /// 広がらず、実装によっては閉じる
    static func sheetGrabber(in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.first { element in
            let name = ((element.identifier ?? "") + " " + (element.label ?? "")).lowercased()
            guard name.contains("grabber") else { return false }
            return element.frame.centerY > snapshot.screen.height * 0.3
        }
    }

    /// 救済(半開きシートを広げての再試行)がレイアウトを変えた可能性を伝える。
    /// **検出できるものは名指しする**: 救済前に横ページャ(`pageIndicator`)があり救済後に
    /// 消えていれば、`direction` がもうページ送りの意味を持たないことまで言う
    /// (2026-08-12実測: Apple マップの経路一覧が横ページャ→縦リストに化けた回。直前の
    /// ft_snapshot の「direction: right で届く」という案内と実際の結果が食い違っていた)。
    /// 消えていない/両方に無いときは汎用の一文のみ(それ以上の推測はしない=誤検知回避)
    static func sheetExpansionLayoutNote(before: SnapshotResponse, after: SnapshotResponse) -> String {
        let generic = " Expanding the sheet may have changed the layout."
        let hadPager = before.elements.contains { $0.type == "pageIndicator" }
        let stillHasPager = after.elements.contains { $0.type == "pageIndicator" }
        guard hadPager, !stillHasPager else { return generic }
        return generic + " The paged layout (pageIndicator) is gone — it looks like the sheet became"
            + " a single vertical list, so `direction` no longer selects which page to advance."
    }

    /// シート展開救済で scrollFrame 容器が実際に伸びたか。伸びていなければ再試行(逆走査
    /// 8本+通常8本)は最初から無駄なので撃たない(2026-08-12実測: Apple マップの乗換案内
    /// シートはグラバーを引いても伸びず、32.5秒かけて同じ失敗をなぞっていた)。
    /// **どちらかの高さを測れなかったら「伸びた」扱い** = 従来どおり再試行する(判断できない
    /// ときに救済を奪わない)。+1 は同一高の描画ゆらぎ吸収
    static func sheetExpansionGrew(beforeHeight: Double?, expandedHeight: Double?) -> Bool {
        guard let beforeHeight, let expandedHeight else { return true }
        return expandedHeight > beforeHeight + 1
    }

    /// シートを広げただけで目標が画面に出たか。出ていれば**再スワイプはしない**
    /// (呼び手の doc 参照 —— この画面ではスワイプがシートの折りたたみに化けるので、
    /// 出した行を自分で引っ込めることになる)。
    ///
    /// **容器で絞らない**のが要点: 探索が `scrollFrame` の中を歩くのは「まだ見えていない行を
    /// 出すため」であって、`scrollTo` が約束しているのは**画面に出ていること**。展開で
    /// シートの見出しごと出てきた場合(実測: `*立川*` は展開後のシート見出し `立川駅` にも当たる)、
    /// 容器の外だからと無視して再スワイプに入るのは、約束を満たしているのに壊しに行く動き。
    ///
    /// 画面内判定は `TapTargetGeometry.offscreenAdvisory`(nil = 画面の中)に委ねる ——
    /// **ここに2つ目の「見えているか」の定義を置かない**。ただし退化 frame(幅か高さ 0)だけは
    /// 手前で落とす: offscreenAdvisory は画面の内側にある 0x0 を「画面内」と答えるので
    /// (2026-08-12 に外して実測)、これが無いと**描かれていない一致で救済を打ち切る**
    static func visibleAfterExpansion(step: FlowStep, in snapshot: SnapshotResponse) -> ElementInfo? {
        guard let locator = step.locator,
              let hit = StepExecutor.match(locator, in: snapshot),
              hit.frame.width > 0, hit.frame.height > 0,
              TapTargetGeometry.offscreenAdvisory(for: hit, screen: snapshot.screen) == nil
        else { return nil }
        return hit
    }

    /// **救済が効かないと分かった画面で、手で開く手順を名指しする**(2026-08-12 の監査)。
    /// 救済が「もう一度やっても同じ」で終わったとき、読み手に残る手は
    /// **グラバーを全開まで引いてから素の ft_snapshot を撮る**(探索が届かなくても、
    /// 展開後の木には行が載る。実測でこれだけが通った)。文言だけの案内では毎回
    /// 座標ドラッグを組み立てさせることになるので、**ref と目標 y まで出す** ——
    /// `ft_drag` は fromRef を取れるので、これはシナリオにも書ける形になる。
    /// グラバーを名指しできない画面では黙る(当てずっぽうの座標は勧めない)
    static func sheetManualExpandHint(_ snapshot: SnapshotResponse) -> String {
        guard let grabber = sheetGrabber(in: snapshot) else { return "" }
        let toY = Int((snapshot.screen.height * expandedSheetTopRatio).rounded())
        return " To open the sheet by hand: ft_drag fromRef: \(grabber.ref) toY: \(toY)"
            + " (that is [\(grabber.ref)] \(RefGuard.describe(grabber))), then read the rows with a"
            + " plain ft_snapshot — a fully expanded sheet lists them even when the scroll search"
            + " cannot walk to them."
    }

    /// 救済(シート展開 + 再試行)が**この画面では効かない**と分かったことを覚える鍵。
    /// **木の指紋そのもの**にする(2026-08-12): 同じ画面で ft_scroll_to を撃ち直すと、
    /// 実測で救済だけに 21.2 秒を再び払っていた —— 1回目の結末は「3回目も同じ」と
    /// 明言しているのに、機械側は次の呼び出しで何も覚えていなかった。
    /// **セレクタごとには割らない**: 効かない理由は画面の性質(リスト内のドラッグが外側シートの
    /// 折りたたみに化ける)であって、何を探しているかではない
    static func sheetRescueKey(_ snapshot: SnapshotResponse) -> String {
        "\(treeFingerprint(snapshot))"
    }

    /// 再試行後の scrollFrame 容器の姿(リスト端でのスワイプが外側シートの折りたたみ/閉鎖に
    /// 化ける画面の検出)。救済前に測れていた容器が再試行後の木から消えていたら `gone`
    /// (2026-08-12実測: Apple マップの乗換案内は再試行のスワイプでシートごと閉じ、
    /// 最終画面が地図だけになっていた)。縮んでいたら `shrunk`。救済前から測れていない
    /// 容器については黙る(嘘を足さない)
    enum SheetRetryContainerState { case silent, shrunk, gone }
    static func sheetRetryContainerState(beforeHeight: Double?, finalHeight: Double?)
        -> SheetRetryContainerState {
        guard let beforeHeight else { return .silent }
        guard let finalHeight else { return .gone }
        return finalHeight < beforeHeight - 1 ? .shrunk : .silent
    }

    /// この長さ未満(ms)の探索は、救済(シート展開)が無ければ内訳を出さない —— 短い探索まで
    /// 毎回「何本振ったか」を出すと、実際に遅い回(2026-08-12実測 9.8/12.8/15.6s)の内訳が
    /// 埋もれる。救済ありは長さに関わらず出す(遅さの主因を切り分けたい回だから)
    static let scrollTimingNoteThresholdMs = 2000

    /// ft_scroll_to の所要時間の内訳(成功時のみ)。**純粋関数**にして計測点(ContinuousClock)と
    /// 切り離す。swipes が nil(runScrollSearch を経由しなかった)でも壊れない
    static func scrollTimingNote(totalMs: Int, swipes: Int?, rescueMs: Int?) -> String {
        guard totalMs >= scrollTimingNoteThresholdMs || rescueMs != nil else { return "" }
        var parts: [String] = []
        if let swipes { parts.append("\(swipes) swipe(s)") }
        if let rescueMs {
            parts.append("sheet-expand rescue +\(Self.elapsedText(milliseconds: Double(rescueMs)))")
        }
        let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: "; ")))"
        return "note: search took \(Self.elapsedText(milliseconds: Double(totalMs)))\(detail).\n"
    }

    /// 「session のアプリが今も前面か」。判定できないドライバでは黙る(嘘を足さない)
    static func foregroundNote(_ sessionBundleID: String?, driver: AppDriver) async -> String {
        guard let bundleID = sessionBundleID else { return "" }
        if let front = (try? await driver.foregroundAppID()) ?? nil {
            return front == bundleID ? " / foreground: yes"
                : " / foreground: no (\(front) is in front — ft_launch to come back)"
        }
        guard let inFront = try? await driver.isAppForeground(bundleID: bundleID) else { return "" }
        return inFront ? " / foreground: yes"
            : " / foreground: no (another app or the home screen is in front — ft_launch to come back)"
    }

    /// 接続中の Android 全台の状態。**1台ずつ独立に見る**(1台落ちていても他を隠さない)
    static func androidFleetStatus(_ serials: [String]) async -> String {
        var lines = ["\(serials.count) Android devices are connected."
            + " Pass serial: (or profile:) to operate one — this listing is status-only."]
        for device in AndroidSerialResolver.describe(serials: serials) {
            let line: String
            if let driver = try? AndroidDriver(serial: device.serial),
               let status = try? await driver.status() {
                let session = status.sessionBundleID ?? "none"
                line = "ready: \(status.ready) / \(device.label) (\(status.osVersion))"
                    + " / session: \(session)"
            } else {
                line = "unreachable / \(device.label) (adb responds but the bridge does not —"
                    + " it starts on the first operation)"
            }
            lines.append("  serial \(device.serial): \(line)")
        }
        return lines.joined(separator: "\n")
    }

    /// 探索が止まった画面で「実際に引けるもの」を列挙する。id とラベルが両方あれば
    /// 両方出す(id だけだと、同じ id を複数のラベルが共有する画面で見分けが付かない)。
    /// **多すぎると読めない**ので上限を切る(足りなければ ft_snapshot を撮ればよい)
    /// **飾りの葉を後回しにする**(2026-08-12 の監査)。実測(Apple マップ・経路詳細で探索が
    /// 止まった回)では、この一覧の 20 枠が地図ピン(`#VKPointFeature "セブン‐イレブン"` 等)で
    /// 埋まり、探していたリストの行が1つも出なかった —— 読み手にとって情報量ゼロの 20 語。
    /// **落とすのではなく順序を落とす**: 枠が余れば従来どおり出す(地図の POI を探している
    /// 回もあるので、消してしまうと逆の実害が出る)。判定は bulk fold・曖昧ラベル注記と同じ
    /// `SnapshotRenderer.isDecorativeLeaf`(2つ目の「飾りか」を作らない)
    static func actionableFirst(_ elements: [ElementInfo],
                                in snapshot: SnapshotResponse) -> [ElementInfo] {
        var actionable: [ElementInfo] = []
        var decorative: [ElementInfo] = []
        for e in elements {
            if SnapshotRenderer.isDecorativeLeaf(e, in: snapshot.elements) {
                decorative.append(e)
            } else {
                actionable.append(e)
            }
        }
        return actionable + decorative
    }

    static func visibleLabelsHint(_ snapshot: SnapshotResponse) -> String {
        var seen = Set<String>()
        var shown: [String] = []
        for e in Self.actionableFirst(snapshot.elements, in: snapshot) {
            // **ゼロ幅文字を落としてから出す**: ここから写したラベルは**見た目が正しいのに
            // 完全一致しない**(2026-08-07 実測。Google マップの発車案内で U+200B が21個
            // 漏れていた。木の描画側は除去済みで、ヒストだけ素通しだった)
            let cleaned = e.label.map(SnapshotRenderer.displayText)
            let id = (e.identifier?.isEmpty == false) ? "#\(e.identifier!)" : nil
            let label = (cleaned?.isEmpty == false) ? "\"\(cleaned!)\"" : nil
            let name = [id, label].compactMap { $0 }.joined(separator: " ")
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            shown.append(name)
            if shown.count >= 20 { break }
        }
        guard !shown.isEmpty else { return "Nothing selectable is on screen." }
        let more = snapshot.elements.count > shown.count ? " …" : ""
        return "On screen where the search stopped: \(shown.joined(separator: " "))\(more)."
    }

    /// スクロール容器の**完全に外**に報告されている要素(ghost)を先頭で名指しする。
    ///
    /// 一覧そのものからは見分けが付かない —— ghost はフルフレームで並ぶので、
    /// 「画面に見えている行」と同じ形で出る(Compose iOS は容器の外の行も木に残す)。
    /// `waitFor` も素の存在しか見ないので、ghost だけで条件が満たされることがある。
    /// **叩けば RefGuard が止める**が、そこまで行かずに気付けるほうが往復が減る
    static func ghostRefs(_ snapshot: SnapshotResponse) -> [Int] {
        snapshot.elements
            .filter {
                RefGuard.isUntappableGhost($0, in: snapshot.elements, screen: snapshot.screen)
                    // **申告されたスクロール容器の外**も同じ印に混ぜる(2026-08-09)。
                    // `isUntappableGhost` の入口は容器の*推測*なので、申告のある UIKit/SwiftUI の
                    // 木では1件も付かず、カードを送って上へ抜けた行が**可視の行と同じ形**で
                    // 並んでいた。利用者から見て原因(そこには描かれていない)も対処
                    // (ft_scroll_to で出してから撮り直す)も同じなので、印は割らない
                    || RefGuard.outsideDeclaredScroller($0, in: snapshot.elements) != nil
            }
            .map(\.ref)
    }

    /// 残像の行に付ける印。**先頭の注記だけでは足りない**(外部フィードバック 2026-08-06):
    /// エージェントは一覧の行から ref をコピーするので、その行自体に出ていないと届かない。
    ///
    /// 積み重なり(`stackedRefs`)にも同じ印を付ける —— 利用者から見ると原因は同じ
    /// 「スクロールの残骸がそこに描かれていない」で、対処(`ft_scroll_to` で出してから撮り直す)
    /// も同じ。**印を2種類に割らない**(見分けても打ち手が変わらないものを増やさない)
    static let leftoverMark = "⚠️scroll-leftover"
    /// 単に画面の外に居るだけの行。**危険度が違うので印を割る**(2026-08-09)。
    /// 上の `ghostFlags` の設計方針は「打ち手が変わらないものは割らない」だが、ここは
    /// **打ち手ではなく危険度**が違う —— leftover は「撃つと別の物に当たる」(沈黙した誤操作)、
    /// offscreen は「今そこに無い」だけ。実測(Apple マップの経路詳細)では、シートを広げた後に
    /// `y=-59` の行まで「別の物に当たるかも」と警告され、本物の leftover と同じ重さで並んでいた
    static let offscreenMark = "⚠️offscreen"

    /// **実計算の回数**(観測用。production の分岐には使わない)。`SnapshotAnnotationCache` 側の
    /// カウンタと違い、**キャッシュを迂回した呼び出しも数える** —— あちらだけを数えると、
    /// 「cache を渡し忘れた呼び出しが1つある」形をテストが素通しする(実際に変異2件が生き延びた)。
    /// 読むテストは直前に 0 を入れて直後に読む: `swift test --parallel` はテストごとに
    /// プロセスを分け、直列実行なら順に走るので、どちらでも他のテストと混ざらない
    static var ghostFlagsComputations = 0

    static func ghostFlags(_ snapshot: SnapshotResponse) -> [Int: String] {
        ghostFlagsComputations += 1
        let refs = Set(ghostRefs(snapshot)).union(RefGuard.stackedRefs(snapshot.elements))
        var flags: [Int: String] = [:]
        for element in snapshot.elements where refs.contains(element.ref) {
            // 画面外判定は DSL と共有(TapTargetGeometry)。2つ目の実装を作らない
            flags[element.ref] = TapTargetGeometry.offscreenAdvisory(
                for: element, screen: snapshot.screen) != nil ? offscreenMark : leftoverMark
        }
        return flags
    }

    /// offscreen 行がどちら側にはみ出しているか(ft_scroll_to の direction 選び用)。
    /// **はみ出し量が大きい軸を主方向にする** —— 斜めにはみ出す要素も1方向へ丸める
    /// (「7px 下 + 400px 右」のような行を両方の見出しへ重複させない)。
    /// `rawValue` はそのまま注記の見出し語、`scrollDirection` は ft_scroll_to の `direction:` の語彙
    /// (指の向きではなく「読み進める内容方向」— below な行は下方向へ読み進めると出てくる = down)
    enum OffscreenDirection: String, CaseIterable {
        case below, above
        case right = "to the right"
        case left = "to the left"

        var scrollDirection: String {
            switch self {
            case .below: return "down"
            case .above: return "up"
            case .right: return "right"
            case .left: return "left"
            }
        }
    }

    /// 実測(Apple マップの経路候補・横ページャ): 第2候補は x=401(画面幅402 の右隣ページ)に居て、
    /// 一度も表示していないのに旧文言「scrolled past」は不正確だった(2026-08-10)。
    /// 中心がどちらの縁をどれだけ超えているかを4方向とも計算し、いちばん超過が大きい方を返す
    static func offscreenDirection(of element: ElementInfo, screen: FTRect) -> OffscreenDirection {
        let cx = element.frame.centerX, cy = element.frame.centerY
        let overflows: [(OffscreenDirection, Double)] = [
            (.below, cy - (screen.y + screen.height)),
            (.above, screen.y - cy),
            (.right, cx - (screen.x + screen.width)),
            (.left, screen.x - cx),
        ]
        // 全方向が非正(=画面内)になることは呼び出し元の条件(offscreenMark 済み)上ないが、
        // 万一そろっても below を既定にして必ず1方向を返す
        return overflows.max { $0.1 < $1.1 }?.0 ?? .below
    }

    /// **collapsingBulk は render() と揃える**(2026-08-10): 畳まれる ref をここでも個別に
    /// 列挙すると、地図 POI のような大量群で出力の半分がこの注記に化ける。
    /// どの ref が畳まれるかは `SnapshotRenderer.foldedGroups` — render 本体と同じ関数 — で決める
    static func ghostNote(_ snapshot: SnapshotResponse, collapsingBulk: Bool = true,
                          cache: SnapshotAnnotationCache? = nil) -> String {
        let flagged = cache?.ghostFlags(snapshot) ?? ghostFlags(snapshot)
        let folded = cache?.foldedGroups(snapshot, flagging: flagged, collapsingBulk: collapsingBulk)
            ?? SnapshotRenderer.foldedGroups(snapshot, flagging: flagged,
                                             collapsingBulk: collapsingBulk)
        let leftovers = snapshot.elements.filter { flagged[$0.ref] == leftoverMark }
        let offscreens = snapshot.elements.filter { flagged[$0.ref] == offscreenMark }
        var note = ""
        if !leftovers.isEmpty {
            note += "note: the \(leftoverMark) rows below are not drawn where their frames say"
                + " (outside their scroll container, or clamped onto another row's frame),"
                + " so tapping them may hit something else:"
                + " \(listRefs(leftovers, folded: folded, in: snapshot.elements))."
                + " Bring them into view with ft_scroll_to first,"
                + " or verify with ft_screenshot\n"
        }
        if !offscreens.isEmpty {
            let byDirection = Dictionary(grouping: offscreens) {
                Self.offscreenDirection(of: $0, screen: snapshot.screen)
            }
            var groups: [String] = []
            var directions: [String] = []
            for direction in OffscreenDirection.allCases {
                guard let elements = byDirection[direction], !elements.isEmpty else { continue }
                groups.append("\(direction.rawValue):"
                    + " \(listRefs(elements, folded: folded, in: snapshot.elements))")
                directions.append(direction.scrollDirection)
            }
            note += "note: the \(offscreenMark) rows below are off the screen, so they are listed"
                + " but not visible — \(groups.joined(separator: " / "))."
                + " Reach them with ft_scroll_to (direction: \(directions.joined(separator: " / ")))"
                + " before using them"
                + Self.pageIndicatorHint(byDirection: byDirection, snapshot: snapshot) + "\n"
        }
        return note
    }

    /// 横ページャ(`pageIndicator`)が居るときだけ、左右の offscreen 行への言い換えを添える
    /// (実測: Apple マップの経路候補・横ページャで、右隣ページの行が「消えた」ように見えた)。
    /// 縦方向(below/above)だけの offscreen では出さない —— 縦スクロールは既に案内済みで、
    /// pageIndicator の有無とは無関係
    private static func pageIndicatorHint(byDirection: [OffscreenDirection: [ElementInfo]],
                                          snapshot: SnapshotResponse) -> String {
        let horizontal = [OffscreenDirection.right, .left]
            .filter { byDirection[$0]?.isEmpty == false }
        guard !horizontal.isEmpty,
              let pager = snapshot.elements.first(where: { $0.type == "pageIndicator" })
        else { return "" }
        let quoted = (pager.value ?? pager.label).map { " \"\(SnapshotRenderer.displayText($0))\"" } ?? ""
        let dirs = horizontal.map(\.scrollDirection).joined(separator: "/")
        let rows = horizontal.flatMap { byDirection[$0] ?? [] }
        return " A horizontal pager\(quoted) is on screen — it renders one page at a time, so the"
            + " \(dirs) rows above are likely just on another page; ft_scroll_to"
            + " (direction: \(dirs)) should reach them."
            + Self.pagerScrollFrameHint(for: rows, in: snapshot)
    }

    /// **特定できたときだけ**足す一文。実測(Apple マップの経路候補・横ページャ): 上の案内どおり
    /// scrollFrame: 無しで撃つと 24.6 秒かけて1ページも動かず、既定の全画面スワイプに落ちて
    /// 地図そのものがパンされた。scrollFrame: に容器を渡すと 3.1 秒で届いた。
    /// 容器は offscreen 行の scrollable な祖先(`TapTargetGeometry.ancestors`)から採る ——
    /// 祖先が1つに決まらない/scrollable な祖先が無い木では黙る(嘘の助言を出さない)
    private static func pagerScrollFrameHint(for rows: [ElementInfo],
                                             in snapshot: SnapshotResponse) -> String {
        var scrollers = Set<Int>()
        for row in rows {
            if let scroller = TapTargetGeometry.ancestors(of: row, in: snapshot.elements)
                .first(where: { $0.scrollable == true }) {
                scrollers.insert(scroller.ref)
            }
        }
        guard scrollers.count == 1, let ref = scrollers.first,
              let container = snapshot.elements.first(where: { $0.ref == ref })
        else { return "" }
        // **id が画面で一意なら #id、でなければ ref**(uniqueScopeID と同じ数え方を使い回す)。
        // 実測: この容器とページャ自身が同じ id を名乗っており(×2)、#id では指せなかった
        let id = container.identifier.flatMap { $0.isEmpty ? nil : $0 }
        let pass = (id.map { Self.idCounts(in: snapshot)[$0] == 1 } ?? false)
            ? "scrollFrame: #\(id!)"
            : "scrollFrame: \(ref) (its ft_snapshot ref — #id here is not unique)"
        return " Pass \(pass) to ft_scroll_to — without it, the default full-screen swipe may pan"
            + " something else (like the map behind it) instead of the pager."
    }

    /// 同じ印の付いた行のうち**最外のものだけ**を残す(2026-08-12 の実アプリ監査)。
    /// 実測(Apple マップの経路詳細)では leftover 8 件のうち 7 件が先頭行の子孫で、
    /// **1つのはみ出しを 8 回読ませて**いた。子孫を撃つときは祖先も必ず同じ状態なので、
    /// 最外だけ名指しても安全上の情報は減らない(行そのものに付く ⚠️ 印は従来どおり全行に出る)。
    /// 返り値の第2要素は落とした件数 —— **黙って消さない**(件数は注記に出す)
    static func outermost(_ elements: [ElementInfo],
                          in all: [ElementInfo]) -> (outer: [ElementInfo], dropped: Int) {
        let refs = Set(elements.map(\.ref))
        let outer = elements.filter { e in
            !TapTargetGeometry.ancestors(of: e, in: all).contains { refs.contains($0.ref) }
        }
        return (outer, elements.count - outer.count)
    }

    /// 注記に並べる ref の列挙。**8件で打ち切る**(全部出すと注記だけで木より長くなる)。
    /// **畳まれた ref は個別に出さず、件数だけ言う**(render 側で ×M の1行に既に畳まれているので、
    /// ここでも列挙すると二重に情報過多になる)
    private static func listRefs(_ elements: [ElementInfo], folded: [String: Set<Int>],
                                 in all: [ElementInfo]) -> String {
        let (outer, descendants) = outermost(elements, in: all)
        let visible = outer.filter { e in
            guard let id = e.identifier else { return true }
            return !(folded[id]?.contains(e.ref) ?? false)
        }
        var parts: [String] = []
        if !visible.isEmpty {
            let listed = visible.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
                .joined(separator: " ")
            parts.append(listed + (visible.count > 8 ? " (+\(visible.count - 8) more)" : ""))
        }
        if descendants > 0 {
            parts.append("(+\(descendants) descendant row(s) of these, same flag)")
        }
        var byID: [String: Int] = [:]
        var order: [String] = []
        // **畳みの集計も outer で数える**: descendants に数えた行をここでも数えると、
        // 同じ1行が「子孫」と「畳まれた」の両方に乗って合計が実際の件数を超える
        for e in outer {
            guard let id = e.identifier, let group = folded[id], group.contains(e.ref) else { continue }
            if byID[id] == nil { order.append(id) }
            byID[id, default: 0] += 1
        }
        parts.append(contentsOf: order.map {
            "(+\(byID[$0]!) folded into the ×\(folded[$0]!.count) id=\($0) line below)"
        })
        return parts.joined(separator: " ")
    }

    /// 木の中に**同じ連続領域が2回**現れる形の注記(監査ラウンド5・2026-08-13・
    /// jma.go.jp を横スクロールした後の iOS Safari で実測)。横スクロールで前後のコピーが
    /// 両方残ると、片方は既にスクロールで動いた実座標を持たないまま木に残る = 読み手が
    /// コピーした ref が古い側かもしれない。
    ///
    /// **判定は `FTCore.DuplicateRegion` が唯一の定義元**(閾値・y/x 制約・誤検知の witness・
    /// アルゴリズムの根拠はそちら。DSL のタップも同じ判定を `StepNote.staleDuplicateRegion`
    /// として運ぶ)。ここが持つのは文言だけ
    static func duplicateRegionNote(_ snapshot: SnapshotResponse) -> String {
        guard let match = DuplicateRegion.find(in: snapshot.elements) else { return "" }
        return "note: the tree appears to list the same \(match.length) elements twice — starting at"
            + " [\(match.firstRef)] and again at [\(match.secondRef)] (same type/label/value, same row,"
            + " shifted x). This happens when a scrollable region moved (e.g. a"
            + " horizontally-scrolled table) but the tree still reports the previous rows"
            + " alongside the new ones — refs from one copy may be stale. Check ft_screenshot to"
            + " see which copy is actually on screen.\n"
    }

    static func lineNote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "note: \(trimmed)\n"
    }

    /// スクロールできる容器の実名の列挙だけ(理由の断定はしない。呼び出し側の文に添える)
    static func scrollAlternativesHint(_ snapshot: SnapshotResponse) -> String {
        let real = ScrollFrameCandidates.candidates(in: snapshot)
            .compactMap(\.selector).prefix(4).joined(separator: " ")
        return real.isEmpty
            ? " No element on this screen declares itself scrollable."
            : " Scrollable areas here: \(real)."
    }

    static func scrollAreaHint(_ snapshot: SnapshotResponse, args: [String: Any]) -> String {
        // **渡した scrollFrame が複数に当たっているなら、それを先に言う**。`matchDetailed` は
        // 添字が無ければ `matches[0]` を黙って採るので、同名の容器が並ぶ画面では
        // preorder 先頭(たいてい横カルーセル)を掴んだまま「見つからない」で終わる。
        // 実測(2026-08-07・Google マップ Android): `#recycler_view` は1画面に4つあり、
        // 注記どおり渡すと高さ126pxのチップ行が選ばれて結果リストは1pxも動かなかった。
        // **ref 指定は曖昧さが無い**(id の重複・欠落を避けるための逃げ道そのものなので、
        // 「他にも当たる」という注記自体が成立しない)。resolveScrollFrameArg 側で
        // 解決済みなのでここでは何も言わない
        if args["scrollFrame"] is Int { return "" }
        // **StepExecutor 側の申告は当てにしない** —— あちらの `pendingScrollFrameNote` は
        // 探索ループの条件分岐の中でしか埋まらず、空振りのまま失敗する回では nil のままになる
        if let frame = args["scrollFrame"] as? String {
            let locator = FTSelector.parse(frame).primary
            let matches = StepExecutor.candidates(locator, elements: snapshot.elements) ?? []
            // **1件も当たらないなら、その事実こそ言う**: 誤字や範囲外の添字でも
            // `scrollContainer` は nil を返し、**2026-08-08 からは探索そのものを打ち切る**
            // (以前は全画面スワイプへ黙って退化していたが、カードのボタン等を誤発火させる
            // 実害があったため fail-fast に変えた。ここは fail-fast の理由文に添える候補列挙)
            if matches.isEmpty {
                // 「search was not run」とはここでは言わない —— fail-fast の理由文
                // (StepExecutor.scrollNotFoundMessage)が既に言っており、このヒントは
                // 成功時の note にも合流するので、断定すると成功メッセージで嘘になる
                return " scrollFrame \"\(frame)\" matches nothing on this screen."
                    + Self.scrollAlternativesHint(snapshot)
            }
            guard locator.index == nil, matches.count >= 2 else { return "" }
            let listed = matches.prefix(4).enumerated().map { index, element -> String in
                let f = element.frame
                return "[\(index)] (\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height)))"
            }.joined(separator: " ")
            return " scrollFrame \"\(frame)\" matches \(matches.count) elements and the first one"
                + " was used — add [n] to pick another: \(listed)."
        }
        // **スクロール容器が1つも申告されない木**では、案内が出せない理由ごと言う(2026-08-08 の
        // 監査)。in-app は版57から Compose/Flutter でも申告できるが、XCUITest エンジンの木では
        // 依然として出ない。黙ると「scrollFrame を渡せ」というツール説明だけが残り、
        // 渡す候補が無いことに気づけない
        if !snapshot.elements.contains(where: { $0.scrollable == true }) {
            return " No element in this tree declares itself scrollable (with Compose/Flutter,"
                + " only the in-app engine can see scroll containers), so the search swiped the"
                + " whole screen. If the target sits in a horizontal row, scroll the row with"
                + " ft_drag inside its bounds; a container that has a #id (testTag) can still be"
                + " passed as scrollFrame:."
        }
        guard let note = ScrollFrameCandidates.note(snapshot) else { return "" }
        return " " + note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 候補選定の規則(装飾葉の除外・スコア付け・編集距離)は `FTCore.SimilarLabels` が唯一の
    /// 定義元(2026-08-15、DSL 側の `StepExecutor.candidateHint` と共有するため降ろした)。
    /// ここは MCP 応答の文言(`"note: similar labels on screen: …"`)の組み立てだけを持つ ——
    /// **この文言は既存の MCP テスト・NoteBudgetTests のバイト数ゲート対象で1文字も変えない**
    static func isSimilarText(_ a: String, _ b: String) -> Bool {
        SimilarLabels.isSimilarText(a, b)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        SimilarLabels.editDistance(a, b)
    }

    /// waitFor が空振りしたとき、画面に**近い**ラベル/id を最大3件挙げる(2026-08-10)。
    /// 実測: 経路ボタンを `waitFor "経路"` と推測したら実ラベルは「計画」で5秒空振りした。
    /// **断定しない**(「これのことでは」とは書かない) —— 似ているというだけで、
    /// 別物を待っていた可能性を否定できる材料は無い。
    /// 同じ target を label/id 両方の経路で見る(`SimilarLabels.candidates` の labelTarget/idTarget
    /// に同じ文字列を渡す) —— どちらの欄で書き間違えたかは読み手にも分からないため
    static func similarLabelsHint(_ selectorText: String, in snapshot: SnapshotResponse) -> String {
        let locator = FTSelector.parse(selectorText).primary
        guard let raw = locator.label ?? locator.id,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let target = FlowMatchMode.normalizeInvisibleCharacters(raw)
        let top = SimilarLabels.candidates(labelTarget: target, idTarget: target, in: snapshot)
        guard !top.isEmpty else { return "" }
        let display = top.map { $0.field == .label ? "\"\($0.matchedText)\"" : "#\($0.matchedText)" }
        return " note: similar labels on screen: \(display.joined(separator: ", "))."
    }

    /// セレクタの**記法**が原因で外れたときだけ出す助言。無条件に「\* で囲め」と言っていた版は
    /// 誤った助言を2形返していた(2026-08-07 に Google マップで実測): 既に `*寿司*` を渡した相手に
    /// 同じ `*寿司*` を勧める / `#no_such_id` に**ラベル部分一致**の `*no_such_id*` を勧める。
    /// 判定は DSL と同じ `StepExecutor.partialMatchHint` に委ねる(3条件そろったときだけ返る)。
    /// 切り詰めラベルの取り違えはそれとは別の形なので独立に足す
    static func notationHint(_ selectorText: String, in snapshot: SnapshotResponse) -> String {
        var parts: [String] = []
        if let hint = SnapshotRenderer.truncatedSelectorHint(selectorText, in: snapshot) {
            parts.append(hint)
        }
        let locator = FTSelector.parse(selectorText).primary
        if let hint = StepExecutor.partialMatchHint(for: locator, in: snapshot.elements) {
            parts.append(" The element is \(hint).")
        }
        if let hint = partialMatchFormHint(locator, in: snapshot.elements) {
            parts.append(hint)
        }
        return parts.joined()
    }

    /// 逆向きの content direction(注記で「戻れ」と言うときの語彙)。
    /// `FTScrollDirection.swipe` と値は同じになるが**意味が違う**(あちらは指の向き)ので別に持つ
    static func reversedDirection(_ direction: FTScrollDirection) -> String {
        switch direction {
        case .down: return "up"
        case .up: return "down"
        case .right: return "left"
        case .left: return "right"
        }
    }

    /// 探索が空振りしたときの記法ヒント。**最終木で出なければ探索を始めた木で見る**(2026-08-15)。
    ///
    /// `notationHint` は渡された1枚の木しか見ないので、部分一致の相手が探索のスワイプで
    /// 画面外へ流れると**ヒントごと黙る** —— 読み手は「`*X*` と書け」を受け取れないまま同じ式で
    /// 撃ち直す。さらに、開始時の木からしか出せなかったということは**その要素はもう後ろにある**
    /// ので、勧めた `*X*` をそのまま同じ向きで撃っても届かない(外部評価 2026-08-15 の実害:
    /// apple.com で `Shop` が8スワイプ空振り → 勧められた `*Shop*` も同じ結果、と報告された)。
    /// **両方の木から出せた回は「探索前から分かっていた」と帰属させる**(下の分岐の理由)。
    /// `backDirection` は探索方向の逆(呼び手が渡す)
    static func scrollNotationHint(_ selectorText: String, after: SnapshotResponse,
                                   beforeScroll: SnapshotResponse?,
                                   backDirection: String) -> String {
        let fromFinal = notationHint(selectorText, in: after)
        let fromStart = beforeScroll.map { notationHint(selectorText, in: $0) } ?? ""
        if !fromFinal.isEmpty {
            // **待たされた理由を帰属させる**(2026-08-15 の追加フィードバック): 開始画面から
            // 同じ答えが出せた回は、スワイプの秒数を丸ごと捨てている。**時間は縮まない**
            // (MCP は1応答なので「これから探します」を先に届ける口が無い)が、
            // 黙っていると「完全一致は即成功・部分一致だけは 24 秒かけて失敗」という
            // 非対称が原因不明のまま残り、同じ書き方を繰り返すことになる
            return fromStart.isEmpty ? fromFinal
                : fromFinal + " This was already true on the screen where the search started,"
                    + " so the swipes could not have helped — when a plain label is not on the"
                    + " current screen, check it for a partial match before scrolling."
        }
        guard !fromStart.isEmpty else { return "" }
        return fromStart + " That was on the screen where this search STARTED — the search has"
            + " since scrolled past it, so re-running with direction: \(backDirection) (or going"
            + " back to that screen first) is what actually reaches it."
    }

    /// **記法の形違い**による部分一致の空振り。実測(2026-08-10): `*武蔵野線`(endsWith)を渡して
    /// 7スクロール空振りした(正解は `*武蔵野線*`)。StepExecutor.partialMatchHint は
    /// 「素の完全一致指定が部分一致なら在る」しか見ないので、**既に endsWith/startsWith を
    /// 指定した相手が別の部分一致形でなら当たる**ケースはここで別に見る。
    /// **既に contains 形(`*x*`)を渡している相手には出ない**(mode が endsWith/startsWith
    /// でなければ何もしないので、誤って同じ助言を繰り返すことはない)
    static func partialMatchFormHint(_ locator: FlowLocator, in elements: [ElementInfo]) -> String? {
        if let label = locator.label, !label.isEmpty, let mode = locator.labelMatch,
           mode == .endsWith || mode == .startsWith,
           !elements.contains(where: { mode.matches($0.label, label) }),
           elements.contains(where: { FlowMatchMode.contains.matches($0.label, label) }) {
            return partialMatchFormText(mode: mode,
                                        typed: mode == .endsWith ? "*\(label)" : "\(label)*",
                                        suggestion: "*\(label)*")
        }
        if let id = locator.id, !id.isEmpty, let mode = locator.idMatch,
           mode == .endsWith || mode == .startsWith,
           !elements.contains(where: { mode.matches($0.identifier, id) }),
           elements.contains(where: { FlowMatchMode.contains.matches($0.identifier, id) }) {
            return partialMatchFormText(mode: mode,
                                        typed: mode == .endsWith ? "#*\(id)" : "#\(id)*",
                                        suggestion: "#*\(id)*")
        }
        return nil
    }

    private static func partialMatchFormText(mode: FlowMatchMode, typed: String,
                                              suggestion: String) -> String {
        let article = mode == .endsWith ? "an ends-with" : "a starts-with"
        let verb = mode == .endsWith ? "ends with" : "starts with"
        return " \"\(typed)\" is \(article) match and nothing \(verb) that text —"
            + " \"\(suggestion)\" (contains) would match here."
    }

    /// スナップショットが上限で打ち切られていたときの注記(欠陥①a)。**打ち切りは配列そのものからの
    /// 脱落**であって描画の省略ではないので、waitFor/scrollTo は打ち切られた要素を一生探し続ける。
    /// 実測: 画面に描画されている `#nav_button` を waitFor が「did not appear」、scrollTo が
    /// 「element not found」としか言わず、存在しない要素を探し続けることになっていた。
    ///
    /// **残っている手の判定は `FTCore.SnapshotTruncation.remedy`(DSL と共有)**。文言だけは
    /// 呼び手ごとに持つ —— MCP は `ft_snapshot maxElements:` と書き、DSL は
    /// `.webView >> ...` / `scrollFrame:` と書く。
    /// **逃げ道まで書く**: 「落ちた中に居るかもしれない」で止めると、読み手は同じ探索を
    /// 撃ち直す(2026-08-12 のブラウザ監査で 45.3s + 56.1s を空費した)
    static func truncationHint(_ snapshot: SnapshotResponse) -> String {
        guard let remedy = SnapshotTruncation.remedy(for: snapshot) else { return "" }
        let escape = truncationEscape(remedy, for: .hint)
        // **`elements.count` を印字しない**(SnapshotTruncation.budgetedCount のレビュー参照):
        // bulk 群は予算の外で送られるので、生の件数は escape が勧める上限より大きく見える。
        // 予算ぶんの件数を出し、bulk が居るときだけ内訳を添える(DSL 側 truncationHint と同型)
        let budgeted = SnapshotTruncation.budgetedCount(snapshot)
        let bulk = SnapshotTruncation.bulkExemptPresentCount(snapshot)
        let bulkClause = bulk > 0 ? " (plus \(bulk) bulk-exempt elements outside the budget)" : ""
        return " (the tree was truncated at \(budgeted) elements\(bulkClause);"
            + " \(snapshot.truncatedCount) more were omitted — the element you are looking for"
            + " may be among them; scrolling will not bring them back, \(escape))"
    }

    /// `truncationHint`/`truncationNote` の2呼び手が使う逃げ道文言。
    /// **文言は呼び手ごとに意図して別々のまま並置している**(docs/design.md の規律:
    /// 「判定は共有・文言は呼び手ごと」)—— ここへ同居させているのは統一するためではなく、
    /// 次に文言を調整するとき両方が編集者の目に入るようにするため。**片方だけ直すな**
    private enum TruncationEscapeStyle {
        case hint
        case note
    }

    private static func truncationEscape(_ remedy: SnapshotTruncation.Remedy,
                                         for style: TruncationEscapeStyle) -> String {
        switch (style, remedy) {
        case (.hint, .raiseLimit(let limit)):
            return "read again with ft_snapshot maxElements: \(limit)"
        case (.hint, .narrowTheScreen):
            return "raising the limit will not help (already at the"
                + " \(BridgeAPI.maxSnapshotElementsCeiling)-element ceiling) — narrow the screen"
                + " (close a sheet, scroll a big list away)"
        case (.note, .raiseLimit(let limit)):
            return "Read again with ft_snapshot maxElements: \(limit) to get them, or narrow"
                + " the screen (close a sheet, scroll a big list away)."
        case (.note, .narrowTheScreen):
            return "Raising the limit will not help (already at the"
                + " \(BridgeAPI.maxSnapshotElementsCeiling)-element ceiling) — narrow the screen"
                + " (close a sheet, scroll a big list away)."
        }
    }

    /// waitFor タイムアウト文の共通末尾(2026-08-12 監査)。waitFor はレンダリング済みの木しか
    /// 見ないので、探した相手がスクロール圏外にいると満額(既定5秒〜)を空費する
    /// (実測: 週間予報表が初期表示の下にあり、25秒2回=52秒を空費した。正解は ft_scroll_to)。
    /// **ft_snapshot(MCPServer+Dispatch.swift)と snapshotAfter(MCPServer+Snapshot.swift)の
    /// 両方が呼ぶ唯一の定義元**(片方だけ変わる事故を防ぐ)。スクロール容器が1つも申告されて
    /// いない画面ではスクロールが答えになり得ないので黙る
    static func waitForScrollHint(in snapshot: SnapshotResponse) -> String {
        guard !ScrollFrameCandidates.candidates(in: snapshot).isEmpty else { return "" }
        return " waitFor only looks at what is currently rendered — if the target is further down,"
            + " use ft_scroll_to (it searches by scrolling)."
    }

    /// WebView の中に**要素が1つも無い縦帯**がある = 木がその部分を落としている疑い。
    ///
    /// なぜ要るか(2026-08-12・Android の Chrome で実測): Chrome は web コンテンツの
    /// a11y ノードを**部分的にしか公開しない**。同じ URL を iOS Safari で読むと全部出るのに、
    /// Android では画面に描かれている「曇一時雨」「時間/降水」の表・「風/波」の行が
    /// **フルツリーにも1つも無い**(スクリーンショットで実在を確認済み)。
    /// 木だけを読む読み手は、そこに何も無いと結論して**黙って誤答する**。
    ///
    /// **判定は `FTCore.TreeCoverage.gap` が唯一の定義元**(閾値・走査・実測の根拠はそちら。
    /// DSL の否定アサーションも同じ判定を `StepNote.treeUnderreported` として運ぶ)。
    /// ここが持つのは**文言だけ**: 「不完全だ」と断定せず、確かめる手段(ft_screenshot)まで書く。
    ///
    /// 1つの応答で名指しする帯の本数。**全部言うのではなく件数だけは必ず言う**
    /// (超えた分は「and N more」)—— 上限を置かないと1画面で帯が10本並びうる
    static let webViewGapBandsReported = 3

    static func webViewGapNote(_ snapshot: SnapshotResponse) -> String {
        guard let gap = TreeCoverage.gap(in: snapshot) else { return "" }
        let bands = gap.bands
        let shown = Array(bands.prefix(webViewGapBandsReported))
        let located: String
        if shown.count == 1, let band = shown.first {
            located = "nothing is listed between y=\(Int(band.y)) and"
                + " y=\(Int(band.y + band.height)) — a band \(Int(band.height)) tall with no"
                + " element at all."
        } else {
            let listed = shown
                .map { "y=\(Int($0.y))-\(Int($0.y + $0.height)) (\(Int($0.height)) tall)" }
                .joined(separator: ", ")
            let more = bands.count > shown.count
                ? ", and \(bands.count - shown.count) more" : ""
            located = "nothing is listed in \(bands.count) separate bands — \(listed)\(more)"
                + "; no element at all in any of them."
        }
        return "note: inside \(RefGuard.describe(gap.container)) \(located) A browser can publish"
            + " only part of a page to the accessibility tree (Android's Chrome does this), so"
            + " text that IS on screen can be missing from this list. Check"
            + " \(shown.count == 1 ? "that band" : "those bands") with ft_screenshot before"
            + " concluding the content is not there; elements missing from the tree cannot be"
            + " waited for, scrolled to, or tapped by selector.\n"
    }

    /// 実体は `FTCore.TreeCoverage.unrepresentedScreenFraction`。ここは呼び出し元の綴りを
    /// 変えないための転送(テストが MCP 側の名前で当てている)
    static func unrepresentedScreenFraction(_ snapshot: SnapshotResponse) -> Double {
        TreeCoverage.unrepresentedScreenFraction(snapshot)
    }

    /// **アドレス欄はあるのに webView 要素そのものが1つも無い**形の検知
    /// (監査ラウンド5・2026-08-13・jma.go.jp を Android Chrome で実測)。
    ///
    /// なぜ要るか: `webViewGapNote` は webView 容器の**内側**しか測れず、`emptyTreeNote` は
    /// `elements.isEmpty` の完全一致でしか発火しない。Chrome が自分の chrome(ツールバー・
    /// アドレス欄)しか公開せず、ページ本体を一切木に出さない画面は、この2本のどちらの網にも
    /// 掛からずに黙って通り抜ける —— 実測(and-browser_jma_notree)は要素19件が全部ブラウザ
    /// chrome で、画面の 88.6%(unrepresentedScreenFraction)が空白のまま報告されていた。
    ///
    /// **既定が a11y になったので、この注記は役目を終えた**(2026-08-14 にユーザー決定で反転)。
    /// a11y から来ているのは**正常**になり、言うことが行動に繋がらない
    /// (足りないときは `missingPageContentNote` が「読み直せ」と言う)。
    /// **常に空を返す** —— 目録から外すと鍵の集合が変わるので、まず黙らせて次のラウンドで消す
    static func browserA11yFallbackNote(_ snapshot: SnapshotResponse) -> String { "" }

    /// 旧実装(既定が DOM だった頃)。**復活させるなら根拠を台帳へ**
    static func browserA11yFallbackNoteLegacy(_ snapshot: SnapshotResponse) -> String {
        guard let id = snapshot.sessionBundleID, WebViewDOM.knownBrowserIDs.contains(id) else { return "" }
        guard !snapshot.elements.contains(where: { $0.web == true }) else { return "" }
        // ブラウザ chrome しか無い画面は別の注記の担当(こちらまで出すと二重に言う)
        guard snapshot.elements.contains(where: { ($0.identifier ?? "").isEmpty }) else { return "" }
        // **`note: ` は各注記が自分で付ける規約**(目録側は付けない。2026-08-14 に付け忘れて
        // この注記だけ書式が揃っていなかった)。末尾の改行も同様
        return "note: the page content below came from the accessibility tree, not the DOM"
            + " — the browser publishes only part of a page there, so text that IS on screen can be missing."
            + " Re-read with ft_snapshot, or check with ft_screenshot before concluding it is absent.\n"
    }

    /// **アドレス欄はあるのに webView 要素そのものが1つも無い**形の注記
    /// (監査ラウンド5・2026-08-13・jma.go.jp を Android Chrome で実測)。
    ///
    /// なぜ要るか: `webViewGapNote` は webView 容器の**内側**しか測れず、`emptyTreeNote` は
    /// `elements.isEmpty` の完全一致でしか発火しない。Chrome が自分の chrome(ツールバー・
    /// アドレス欄)しか公開せず、ページ本体を一切木に出さない画面は、この2本のどちらの網にも
    /// 掛からずに黙って通り抜ける —— 実測(and-browser_jma_notree)は要素19件が全部ブラウザ
    /// chrome で、画面の 88.6% が空白のまま報告されていた。
    ///
    /// **判定は `FTCore.TreeCoverage.missingPageContent` が唯一の定義元**(閾値・ブラウザに
    /// 絞る理由・witness の実測はそちら)。ここが持つのは文言だけ
    static func missingPageContentNote(_ snapshot: SnapshotResponse) -> String {
        guard TreeCoverage.missingPageContent(in: snapshot) else { return "" }
        // **次の一手まで書く**(2026-08-14 に原因が判った)。Chromium は a11y を要求する
        // サービスが繋がってから木を作り、**出来上がるまで数秒かかる**。その窓で撮ると
        // chrome だけが返る(実測: ブリッジ起動直後 19 要素 → 5 秒後 135 要素で安定)。
        // 恒久的な故障ではないので、まず読み直させる —— 以前は screenshot しか勧めておらず、
        // 「このページは読めない」と結論させていた
        return "note: the browser published no page content to the accessibility tree at all —"
            + " not even a webView container, only its own chrome (address bar, toolbar, tabs)."
            + " If the bridge was just started, the tree can be empty for a few seconds while the"
            + " browser builds it — read again with ft_snapshot before concluding anything."
            + " Elements missing from the tree cannot be waited for, scrolled to, or tapped by"
            + " selector; ft_screenshot shows what is actually on screen.\n"
    }

    /// センターX が近い(=セルが中央揃えで縦に並ぶ)ことを列とみなす許容誤差。**容器幅の比率**
    /// (iOS=pt/Android=px の桁違いを吸収する)。実測(2026-08-12・tenki.jp 2週間天気)では
    /// 同じ日付列内の要素(天気アイコン・気温・降水確率)の centerX 差は 2px 未満だった
    static let gridColumnCenterToleranceRatio = 0.02
    /// 同じ行とみなす y 区間の重なり(Jaccard = 交差 / 和集合)。幅ベースの overlap/min(width) は
    /// 不採用(2026-08-12実測): ナビの全幅リンクのような大きな要素に、無関係な小要素が
    /// 「収まっている」というだけで同じ列に巻き込まれた(実際に3件の誤検知を作った)
    static let gridRowOverlapRatio = 0.6
    static let gridMinColumns = 3
    static let gridMinRows = 2
    /// **見出し行が入る余地**の下限。格子の直上の空白が「行の間隔(pitch)の何倍あれば
    /// 1行ぶん抜けたと言えるか」。
    ///
    /// なぜ要るか(2026-08-13・Yahoo!天気を iOS Safari で実測。**実アプリでの初めての誤検知**):
    /// 見出し行そのものが値の行と centerX で揃っていると、**見出しは格子の最上行として鎖に
    /// 取り込まれ**、その上の余白(見出しのさらに上の段落間)が「見出しが無い」と読まれる。
    /// 実測比 = 空白 / pitch: 誤検知 **1.16**(週間表: 22px / 19px)・**0.54**(時間別の表:
    /// 19px / 35px)に対し、真陽性の witness(and-browser_weektable)は **4.4**(286px / 65px)。
    /// 2.0 はその間で、**「抜けた行1つぶんの高さ+その上下の余白」が要る**という読みでもある
    static let gridHeaderRoomRatio = 2.0

    /// 値のセル(格子)はツリーにあるのに、その真上の見出し行(列ヘッダ)が無い形の検知。
    /// `webViewGapNote` は「どこかに空白がある」としか言わないので、格子であることと
    /// 見出しが無いことを名指しする。
    ///
    /// なぜ要るか(2026-08-12・Android の Chrome で実測): tenki.jp の2週間天気で、
    /// 日付ヘッダ行(「日付 / 12日(水) / 13日(木) / …」)がツリーから丸ごと欠落しているのに、
    /// 値のセル(天気・気温・降水確率)は木にある。読み手は列と日付を取り違えて
    /// **警告なしに誤答**しうる。
    ///
    /// **対象は webView の中だけ**(webViewGapNote と同じ前提: ブラウザだけが a11y ツリーを
    /// 部分的にしか出さない)。ネイティブ UI のボタン格子(電話キーパッド等)は同じ理由で
    /// 見出しを持たないことが多く、webView に絞らずに実装した初版では実測で5件の誤検知が
    /// 出た(ダイヤルパッドの数字キー・URL バーのツールバーアイコン等)。webView に絞ると
    /// 固定コーパス30枚のうち0件に減った
    static func gridWithoutHeaderNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false) -> String {
        for container in snapshot.elements where container.type == "webView" {
            guard let grid = gridHeaderGap(in: container, of: snapshot) else { continue }
            guard !abbreviated else {
                return "note: a value grid's header row may be missing from the tree"
                    + " (see the first snapshot's note).\n"
            }
            return "note: inside \(RefGuard.describe(container)), a \(grid.columns)x\(grid.rows)"
                + " grid of values starts at y=\(Int(grid.band.y + grid.band.height)), but nothing"
                + " is listed above its columns (y=\(Int(grid.band.y))-"
                + "\(Int(grid.band.y + grid.band.height))) — its header row (e.g. column labels)"
                + " may be missing from the accessibility tree; a browser can publish only part of"
                + " a page (Android's Chrome does this). Read the header with ft_screenshot before"
                + " matching values to it, and match cells by x position, not tree order — the"
                + " tree can list one column's rows before the next column starts.\n"
        }
        return ""
    }

    /// 隣接する2行の間で、centerX が最も近い要素どうしを対応付ける(貪欲最近傍・1対1)。
    /// 呼び出し順(rowA の並び)に依らず結果は幾何だけで決まる
    private static func matchAdjacentColumns(_ rowA: [ElementInfo], _ rowB: [ElementInfo],
                                             tolerance: Double) -> [(ElementInfo, ElementInfo)] {
        var used = Set<Int>()
        var matches: [(ElementInfo, ElementInfo)] = []
        for a in rowA {
            var best: ElementInfo?
            var bestDistance = tolerance + 1
            for b in rowB where !used.contains(b.ref) {
                let distance = abs(a.frame.centerX - b.frame.centerX)
                if distance <= tolerance, distance < bestDistance {
                    best = b
                    bestDistance = distance
                }
            }
            if let best {
                used.insert(best.ref)
                matches.append((a, best))
            }
        }
        return matches
    }

    private static func yJaccard(_ a: ElementInfo, _ b: ElementInfo) -> Double {
        let aTop = a.frame.y, aBottom = a.frame.y + a.frame.height
        let bTop = b.frame.y, bBottom = b.frame.y + b.frame.height
        let overlap = min(aBottom, bBottom) - max(aTop, bTop)
        guard overlap > 0 else { return 0 }
        let union = max(aBottom, bBottom) - min(aTop, bTop)
        return union > 0 ? overlap / union : 0
    }

    /// y の Jaccard が閾値以上の要素どうしを推移閉包で同じ行にまとめ、平均 y の昇順で返す
    private static func rowBands(_ leaves: [ElementInfo]) -> [[ElementInfo]] {
        var parent = Array(0..<leaves.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for i in 0..<leaves.count {
            for j in (i + 1)..<leaves.count
            where yJaccard(leaves[i], leaves[j]) >= gridRowOverlapRatio {
                union(i, j)
            }
        }
        var groups: [Int: [ElementInfo]] = [:]
        for i in 0..<leaves.count { groups[find(i), default: []].append(leaves[i]) }
        // **並びは全順序にする**: Dictionary の列挙順はプロセスごとに変わるので、平均 y が
        // 同値の帯を y だけで並べると発火が run ごとに揺れる(発火集合を等号で固定している
        // GridWithoutHeaderNoteTests が偶に落ちる形)。同値は最小 ref で決める
        return groups.values.sorted {
            (averageY($0), $0.map(\.ref).min() ?? 0) < (averageY($1), $1.map(\.ref).min() ?? 0)
        }
    }

    private static func averageY(_ elements: [ElementInfo]) -> Double {
        elements.isEmpty ? 0 : elements.map(\.frame.y).reduce(0, +) / Double(elements.count)
    }

    /// 格子の**直上に空いている高さ**(格子の列が占める x 範囲だけを見る)。
    /// **葉限定にしない**(emptyBands と同じ判断): 実測したフィクスチャの depth 列には
    /// 「兄弟が祖先に見える」欠けがあり(TapTargetGeometry.ancestors の doc 参照)、
    /// 見出しの一部(例: `(水)`)が isLeaf 判定から漏れて「空」に見えることがあった。
    /// 容器サイズ未満という緩い条件に寄せ、ラベルの有無を問わず何か描かれていれば空きを縮める。
    ///
    /// **最上行の仲間は除く** —— 鎖に入らなかった同じ行の要素(行見出しの列など)は
    /// gridTop より上に始まることがあり、数えると常に空きゼロになる。
    /// 上端をまたぐ要素(下端が gridTop より下)は**負の空き**を返す ——
    /// 呼び出し側の下限(`room >= pitch * ratio`・pitch > 0)がそのまま弾くので、
    /// 「またいでいる = 空白を埋めている」の意味になる
    private static func roomAboveGrid(topRow: [ElementInfo], gridTop: Double,
                                      columns: (minX: Double, maxX: Double),
                                      in container: ElementInfo,
                                      of snapshot: SnapshotResponse) -> Double {
        let topRowRefs = Set(topRow.map(\.ref))
        let edges = StepExecutor.descendants(of: container, in: snapshot.elements)
            .filter { element in
                !topRowRefs.contains(element.ref) && element.scrollable != true
                    && element.frame.height < container.frame.height
                    && element.frame.y < gridTop
                    && element.frame.x < columns.maxX
                    && element.frame.x + element.frame.width > columns.minX
            }
            .map { $0.frame.y + $0.frame.height }
        return gridTop - (edges.max() ?? max(container.frame.y, snapshot.screen.y))
    }

    /// 行の間隔の代表値(隣り合う行の平均 y の差の中央値)。**平均でなく中央値**:
    /// 実測の格子は途中に別セクションの行が挟まって間隔が飛ぶ(and-browser_weektable の
    /// 53/65/**184**/53/65)ので、平均だと1本の飛びに引きずられる
    private static func rowPitch(_ rows: [[ElementInfo]]) -> Double {
        let centers = rows.map(averageY)
        guard centers.count >= 2 else { return 0 }
        let gaps = zip(centers.dropFirst(), centers).map { $0 - $1 }.sorted()
        return gaps[gaps.count / 2]
    }

    /// webView 1つぶんの格子探索。**列は「隣接する行どうしが centerX で揃う」連鎖でだけ決める**
    /// (2026-08-12): 幅の重なり(overlap/min-width)や全画面での列クラスタリングは、無関係な
    /// 要素(ナビの並び・ツールバーのアイコン)を座標の偶然一致で同じ列/行へ巻き込み、実測で
    /// 複数の誤検知を作った。隣接行だけを見る連鎖にすると、そもそも隣り合わない要素同士が
    /// 結び付くことがない。連鎖で残った列は**構造上つねに全セル埋まる**ので、
    /// 「格子の充填率 0.7 以上」という要件は連鎖の成立条件そのものに埋め込まれている
    /// (別途しきい値を持たない)
    private static func gridHeaderGap(in container: ElementInfo, of snapshot: SnapshotResponse)
        -> (columns: Int, rows: Int, band: FTRect)? {
        let leaves = StepExecutor.descendants(of: container, in: snapshot.elements).filter { element in
            guard element.scrollable != true,
                  TapTargetGeometry.isLeaf(element, in: snapshot.elements) else { return false }
            let label = (element.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (element.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !label.isEmpty || !value.isEmpty
        }
        guard leaves.count >= 6 else { return nil }
        let tolerance = container.frame.width * gridColumnCenterToleranceRatio
        let bands = rowBands(leaves)
        var index = 0
        while index < bands.count - 1 {
            var run = [bands[index]]
            var cursor = index
            while cursor + 1 < bands.count {
                let matched = matchAdjacentColumns(run[run.count - 1], bands[cursor + 1],
                                                    tolerance: tolerance)
                guard matched.count >= gridMinColumns else { break }
                run.append(bands[cursor + 1])
                cursor += 1
            }
            defer { index = cursor > index ? cursor : index + 1 }
            guard run.count >= gridMinRows else { continue }
            // 連鎖を通して残る列だけを数える(先頭行の各要素を起点に、隣接行との対応が
            // 最後まで続くもの。実測: 「日付ラベル」列は温度・降水確率の行には対応が無く
            // 自然に脱落する)
            var chains: [[ElementInfo]] = run[0].map { [$0] }
            for row in run.dropFirst() {
                let previous = chains.map { $0[$0.count - 1] }
                let matched = Dictionary(uniqueKeysWithValues:
                    matchAdjacentColumns(previous, row, tolerance: tolerance).map { ($0.0.ref, $0.1) })
                chains = chains.compactMap { chain in matched[chain[chain.count - 1].ref].map { chain + [$0] } }
            }
            guard chains.count >= gridMinColumns else { continue }
            let topMembers = chains.map { $0[0] }
            guard let gridMinX = topMembers.map(\.frame.x).min(),
                  let gridMaxX = topMembers.map({ $0.frame.x + $0.frame.width }).max(),
                  let gridTop = topMembers.map(\.frame.y).min() else { continue }
            // **見出し行が入る余地があるときだけ言う**(gridHeaderRoomRatio の宣言参照)。
            // 見出しが値と同じ列に揃っていると鎖の最上行として取り込まれるので、
            // 「直上が空か」だけでは見出しの在る格子と区別が付かない
            let pitch = rowPitch(run)
            let room = roomAboveGrid(topRow: run[0], gridTop: gridTop,
                                     columns: (gridMinX, gridMaxX),
                                     in: container, of: snapshot)
            guard pitch > 0, room >= pitch * gridHeaderRoomRatio else { continue }
            // **鎖の最上行そのものが見出し行なら黙る**(chainsHaveHeaderTopRow の doc 参照)。
            // room 比のガードは「直上に見出し1行ぶんの空きがあるか」しか見ないので、その空きを
            // 作ったのが見出しとは無関係の別要素でも通ってしまう(witness は同 doc)
            guard !chainsHaveHeaderTopRow(chains) else { continue }
            let band = FTRect(x: gridMinX, y: gridTop - room, width: gridMaxX - gridMinX,
                              height: room)
            return (chains.count, run.count, band)
        }
        return nil
    }

    /// **鎖の最上行が見出し行そのものに見えるか**(internal = GridWithoutHeaderNoteTests から届く)。
    ///
    /// なぜ要るか(2026-08-15・J1順位表を iOS Safari(Simulator)/ Android Chrome(Emulator)で実測):
    /// `gridHeaderRoomRatio` は「直上に見出し1行ぶんの空きがあるか」しか見ないので、その空きを
    /// **見出しとは無関係の別要素**(ページ内の「Ｊ１」「2026/27」セレクタが a11y から落ちている)
    /// が作った画面でも通ってしまう(iOS: room/pitch=2.6・y=438 の 7x2 / Android: y=1318 の 6x2、
    /// どちらも最上行が「順位/クラブ/勝点/…」の実見出しなのに発火した)。room 比だけでは
    /// 区別できないので、**最上行の中身**を見る: 全列が「最上のセルは数字でなく、その列の
    /// 下のセル全部が数字」を満たすなら、最上行こそ見出し行なので黙る。
    /// **全列が満たすことを要求する**(一部の列だけでは緩めない = 真陽性(and-browser_weektable)を
    /// 消す側に倒さない)
    static func chainsHaveHeaderTopRow(_ chains: [[ElementInfo]]) -> Bool {
        guard !chains.isEmpty else { return false }
        return chains.allSatisfy { chain in
            guard let top = chain.first else { return false }
            let below = chain.dropFirst()
            guard !below.isEmpty else { return false }
            return !isGridDigitsOnlyText(gridHeaderJudgeText(top))
                && below.allSatisfy { isGridDigitsOnlyText(gridHeaderJudgeText($0)) }
        }
    }

    /// 見出し判定に使う文字列。**label が空なら value**(gridHeaderGap の葉抽出と同じ優先順)
    private static func gridHeaderJudgeText(_ element: ElementInfo) -> String {
        let label = (element.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? (element.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : label
    }

    /// ASCII 数字 `0-9` / 全角数字 `０-９` だけで構成されるか。空文字は数字ではない
    private static func isGridDigitsOnlyText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy {
            (0x30...0x39).contains($0.value) || (0xFF10...0xFF19).contains($0.value)
        }
    }

    /// アドレス欄の identifier 既知集合(実測 2026-08-12)。Android Chrome = `url_bar` /
    /// iOS Safari = `TabBarItemTitle`(通常時)・`URL`(アドレス欄をタップした状態)。
    ///
    /// **「値が URL らしい textField」というフォールバックは置かない**(2026-08-12 に実装して撤回)。
    /// ドットを含む値は住所欄でもメール欄でも普通に出るので、**WebView を載せたアプリの
    /// 入力画面で誤って「アドレス欄」と名乗る** —— そしてその形は固定コーパス(ブラウザ6枚は
    /// すべて既知 identifier を持つ)には1枚も無いので、「誤検知0」の確認が効かない。
    /// 名前の分かるブラウザだけを名指しし、知らないブラウザについては黙る
    /// 実体は `FTCore.TreeCoverage.addressBarCandidate`(identifier のリテラルは1箇所)。
    /// 2つの呼び手が逆の前提で使う: `addressBarElement` は webView が居るときだけ通す
    /// (addressBarNote)/ `missingPageContent` は逆に webView が**居ない**ことを条件にする
    private static func addressBarCandidate(in snapshot: SnapshotResponse) -> ElementInfo? {
        TreeCoverage.addressBarCandidate(in: snapshot)
    }

    private static func addressBarElement(in snapshot: SnapshotResponse) -> ElementInfo? {
        guard snapshot.elements.contains(where: { $0.type == "webView" }) else { return nil }
        return addressBarCandidate(in: snapshot)
    }

    /// ブラウザのアドレス欄を名指しする注記。**木だけで判定**(driver・セッション状態は使わない)。
    ///
    /// なぜ要るか(2026-08-12実測): `ft_open_url` に同じ URL を渡しても、iOS Safari はフル版、
    /// Android Chrome は `/lite/` へリダイレクトされた別のページを表示していた。ツリーの中身も
    /// 別物になるが、応答のどこにもそのことに気付く手掛かりが無かった
    static func addressBarNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false) -> String {
        guard let bar = addressBarElement(in: snapshot),
              let raw = bar.value, !raw.isEmpty else { return "" }
        let value = SnapshotRenderer.displayText(raw)
        guard !abbreviated else {
            return "note: the address bar shows \"\(value)\" (see the first snapshot's note).\n"
        }
        return "note: the address bar shows \"\(value)\" — a browser can silently redirect to a"
            + " different page (mobile/lite version) than the one requested, and this value may"
            + " itself be shortened by the browser. Check the exact page with ft_screenshot if"
            + " that matters.\n"
    }

    /// ラベルが**見えている文字ではなく URL の断片**になっているリンク。
    ///
    /// なぜ要るか(2026-08-12・Android の Chrome で実測): アクセシブルな名前を持たないリンクに
    /// Chrome は URL を入れる。実物は `"13101"`(市区町村リンク=画面には「千代田区」と描画)・
    /// `"dc2557a17fdf039c74261b0b5da109ec"`・`"details%3Fid%3Dcom…"`(400字超)。
    /// **黙っていると読み手はこれを画面の文字だと読む** —— 同じ画面を iOS Safari で読むと
    /// ちゃんと「千代田区」なので、OS 差が「アプリの差」に見える。
    ///
    /// **数字だけの形は判定に入れない**(`13101`): 本文の数値(気温・件数)と区別が付かず、
    /// 誤検知のほうが害になる。ここで名指しできるのは「人が書いた文には出ない綴り」だけ
    ///
    /// **webView の中だけを見る**(2026-08-15。E2EAppCMP のライフサイクル画面が witness):
    /// この注記の主張は「ブラウザがアクセシブル名の無いリンクに URL を入れた」という**機構**なので、
    /// ブラウザが関与しない木で言うと**2重に誤る** —— 実測では、契約で URL を丸ごと表示する
    /// ネイティブの `Text`(`#txt_last_deeplink` = `deeplink=fte2ecmp://screen/lifecycle`)に対して
    /// 「the browser fell back to the link target」と述べ、さらに
    /// 「画面の文字ではないので ft_screenshot で読め」と**正しいラベルを疑うよう勧めていた**。
    /// 実際はラベルこそが画面に描かれている文字。ゲートは `addressBarElement` と同じ考えだが、
    /// **こちらは要素ごとに名指しする**ので容器の中に居ることまで要る
    static func urlishLabelsNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false) -> String {
        let insideWebView = webViewDescendantRefs(in: snapshot)
        let urlish = snapshot.elements.filter {
            insideWebView.contains($0.ref) && looksLikeURLFragment($0.label)
        }
        guard !urlish.isEmpty else { return "" }
        guard !abbreviated else {
            return "note: \(urlish.count) link label(s) are URL fragments, not on-screen text"
                + " (see the first snapshot's note).\n"
        }
        let listed = urlish.prefix(4).map { "[\($0.ref)]" }.joined(separator: " ")
        let more = urlish.count > 4 ? " (+\(urlish.count - 4) more)" : ""
        return "note: the label of \(listed)\(more) is a URL fragment, not the text drawn on"
            + " screen — the browser fell back to the link target because the link has no"
            + " accessible name. Do not report these as page content, and do not build a selector"
            + " from them; read what they say with ft_screenshot and tap them by ref.\n"
    }

    /// webView 容器の子孫の ref(容器が複数あれば全部)。**容器自身は含めない**
    static func webViewDescendantRefs(in snapshot: SnapshotResponse) -> Set<Int> {
        var refs = Set<Int>()
        for container in snapshot.elements where container.type == "webView" {
            for element in StepExecutor.descendants(of: container, in: snapshot.elements) {
                refs.insert(element.ref)
            }
        }
        return refs
    }

    /// URL 断片らしさ。**人が書いた文には出ない綴りだけ**を見る(百分率エンコード・
    /// クエリ文字列・スキーム・長い16進トークン)
    static func looksLikeURLFragment(_ label: String?) -> Bool {
        guard let label, label.count >= 8 else { return false }
        if label.contains("://") { return true }
        // %XX が2つ以上(1つだけなら「50%OFF%」のような本文と紛れる)
        var percent = 0
        var index = label.startIndex
        while let found = label[index...].firstIndex(of: "%") {
            let after = label.index(after: found)
            guard let second = label.index(after, offsetBy: 1, limitedBy: label.endIndex),
                  second < label.endIndex,
                  label[after].isHexDigit, label[second].isHexDigit else {
                index = after
                if index >= label.endIndex { break }
                continue
            }
            percent += 1
            if percent >= 2 { return true }
            index = label.index(after: second)
            if index >= label.endIndex { break }
        }
        // `a=b&c=d` 形のクエリ(= と & が両方あり、空白を含まない)
        if label.contains("="), label.contains("&"), !label.contains(" ") { return true }
        // 24 文字以上の16進トークン(広告 ID・ハッシュ)
        let hex = label.filter { $0.isHexDigit }
        if hex.count >= 24, hex.count == label.count { return true }
        return false
    }

    /// **ラベルも id も無い clickable**の注記(欠陥⑨)。座標か ref でしか指定できず、
    /// シナリオでは安定したセレクタを書けないことを伝える。実測: 経路の移動手段タブ(アイコンのみ)
    /// が id もラベルも無い `clickable` として出て、書ける手段が何も無いことに気付けなかった
    /// `abbreviated`(F-6 の対象拡大・2026-08-10): 明細(`listed`)は既定と同じまま、
    /// 冒頭の長い advice だけ「初出の注記を見よ」に圧縮する。呼び手は once 経由(instance の
    /// `unlabeledClickablesNote(_:)` ラッパ)で使い分ける
    static func unlabeledClickablesNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false,
                                        cache: SnapshotAnnotationCache? = nil) -> String {
        // **候補を先に絞ってから grade する**(2026-08-13 のレビュー指摘)。木の全要素を
        // 無条件に grade すると、**注記が1バイトも出ない画面で最も高くつく** ——
        // 実測(debug・固定コーパス)で 233 要素の画面が 3497ms、120 要素で 1208ms。
        // ft_snapshot 全体が 203 要素で 1.2 秒(監査17)なので、桁で効いてしまう。
        // grade するのは**候補と同じ矩形の要素だけ**にする
        let candidates = snapshot.elements.filter {
            $0.type == "clickable" && ($0.identifier ?? "").isEmpty && ($0.label ?? "").isEmpty
        }
        guard !candidates.isEmpty else { return "" }
        // **filter の外で1回だけ求める**(2026-08-13 のレビュー指摘): クロージャの中で呼ぶと
        // 候補ごとに全要素走査と集合の再構築が走り、`cache: nil` なら `SelectorNaming` まで
        // 作り直していた —— 直前に直した性能問題と同じ形を、同じ関数で作っていた
        let twins = stableTwinFrames(candidates, in: snapshot, cache: cache)
        let unlabeled = candidates.filter { !twins.contains(frameKey($0.frame)) }
        guard !unlabeled.isEmpty else { return "" }
        let listed = unlabeled.prefix(8).map { element -> String in
            scopedSelector(for: element, in: snapshot).map { "[\(element.ref)] = \($0)" }
                ?? "[\(element.ref)]"
        }.joined(separator: " ")
        let more = unlabeled.count > 8 ? " (+\(unlabeled.count - 8) more)" : ""
        let advice: String
        if abbreviated {
            advice = " — see the first snapshot's note for how to target them."
        } else {
            // **「セレクタを書けない」は嘘だった**(2026-08-09): id を持つ祖先があれば
            // `#container >> .clickable[n]` で書ける(スコープ記法。docs/commands.md)。
            // 実測(Google マップの移動手段タブ)では id もラベルも無い clickable が
            // `#directions_mode_tabs` の中に居り、この形で一意に指せた。
            // 祖先も名無しのときだけ「ref か座標しかない」が正しい
            let writable = unlabeled.contains { scopedSelector(for: $0, in: snapshot) != nil }
            advice = writable
                ? " — a plain label/#id selector cannot pick them, but the ones shown with"
                    + " \"= …\" sit inside a container that has an id, so a scenario can select them"
                    + " with that scoped selector. The rest can only be targeted by ref or coordinates."
                    + " Those scoped selectors are index-based: they break if the number of same-type"
                    + " siblings changes, so treat them as a last resort and prefer asking the app"
                    + " for an id."
                : " — they can only be targeted by ref or coordinates,"
                    + " so a scenario cannot select them with a stable selector."
        }
        return "note: \(unlabeled.count) clickable element(s) have neither a label nor an id"
            + " (\(listed)\(more))\(advice)\n"
    }

    /// **同じ矩形に、書けるセレクタを持つ要素が居るか**(2026-08-13・設定アプリの監査)。
    ///
    /// iOS の設定アプリは行を `clickable` の容器で包み、**その中に同じ矩形の
    /// `button` + `#id`** を置く。素の判定では容器のほうが「ラベルも id も無い」に該当し、
    /// **ホーム画面で 11 件・一般で 20 件**が「安定したセレクタで指せない」と報告されていた。
    /// しかし実際には `#com.apple.settings.general` が**同じ矩形にある**ので、
    /// 注記が勧める索引付きスコープ記法(`#…collectionView >> .clickable[3]`・兄弟の数で壊れる)
    /// より**明らかに良い書き方が存在する**。注記の前提(「書けない」)自体が偽だった。
    ///
    /// 判定は**矩形の一致**だけにする(祖先・子孫の関係は見ない) —— 同じ場所を撃つなら
    /// タップ結果は同じで、木の形は OS ごとに違うため。**一致は丸めた完全一致**(近似にしない)
    /// —— 緩めるほど「隣の行のセレクタで代用できる」と誤って黙る側へ倒れるので、
    /// 観測した形(容器と中身が同一矩形)にだけ効かせる
    /// **`.stable` の要素だけを数える**(2026-08-13 に自分で踏んだ): `selector(for:)` は索引付きの
    /// スコープ記法も返すので、素で使うと**無ラベル clickable 自身が「書ける」に該当し、
    /// 自分自身を twin として黙る**(コーパスで ios-home / ios-maps_route_options の
    /// 真陽性まで消えた)。注記の趣旨は「索引記法より良い、位置に依存しない書き方がある」
    /// なので、`.indexed` は代替として数えない
    /// **`cache` を必ず通す**(2026-08-13 のレビュー指摘): 自前で `SelectorNaming` を作ると、
    /// 曖昧ラベル・重複 id のある画面で**同じ応答の中で二度 grade する**。しかも
    /// `MCPAnnotationCacheTests` の計数は共有インスタンスしか見ないので、
    /// **二重計算がテストから見えない**(キャッシュの doc が warn している盲点そのもの)
    static func stableTwinFrames(_ candidates: [ElementInfo], in snapshot: SnapshotResponse,
                                 cache: SnapshotAnnotationCache?) -> Set<String> {
        let candidateFrames = Set(candidates.map { frameKey($0.frame) })
        let naming = cache?.selectorNaming(snapshot) ?? SelectorNaming(snapshot)
        var keys: Set<String> = []
        for element in snapshot.elements {
            let key = frameKey(element.frame)
            guard candidateFrames.contains(key), !keys.contains(key),
                  let graded = naming.graded(for: element, in: snapshot),
                  graded.durability == .stable else { continue }
            keys.insert(key)
        }
        return keys
    }

    static func frameKey(_ frame: FTRect) -> String {
        "\(frame.x.rounded()),\(frame.y.rounded()),\(frame.width.rounded()),\(frame.height.rounded())"
    }

    /// 1回の応答組み立て(snapshotBody / scrollTo)に**閉じた**計算の使い回し。
    /// **寿命は呼び出し元のローカル変数だけ**——インスタンスをまたいで保持すると、木が変わった後の
    /// 応答が古い ghost/graded を返す事故になるので、MCPServer の instance state
    /// (refGenerations 等)には絶対に置かない。呼び出し元は snapshot を撮り直すたびに
    /// 新しいインスタンスを作ること(このクラス自身は「同じ snapshot 値に対して同じ答えを返す」
    /// こと以上は保証しない)。
    ///
    /// 実測(2026-08-12・実アプリ 203 要素画面): 素の呼び出しは同じ木に対して ghostFlags を
    /// 3回・foldedGroups を2回払い、ambiguousLabelsNote と duplicateIDsNote は別々の
    /// SelectorNaming を作るので、両方の群に出る要素の graded が二重に走ることがあった。
    final class SnapshotAnnotationCache {
        private var ghostFlagsResult: [Int: String]?
        /// collapsingBulk の値で結果が変わる(duplicateIDsNote は常に true で引く一方、
        /// ghostNote/render は expandBulk 引数由来の値)ので bool をキーにする
        private var foldedGroupsResults: [Bool: [String: Set<Int>]] = [:]
        private var namingInstance: SelectorNaming?

        /// テストが「1応答で1回だけ計算したか」を確かめるための実計算回数(キャッシュヒットは
        /// 数えない)。production の分岐には使わない——観測用のカウンタを増やすだけ
        private(set) var ghostFlagsComputeCount = 0
        private(set) var foldedGroupsComputeCount = 0
        /// `SelectorNaming.gradedComputeCount` への転送(naming が未生成なら 0)
        var gradedComputeCount: Int { namingInstance?.gradedComputeCount ?? 0 }

        func ghostFlags(_ snapshot: SnapshotResponse) -> [Int: String] {
            if let ghostFlagsResult { return ghostFlagsResult }
            ghostFlagsComputeCount += 1
            let result = MCPServer.ghostFlags(snapshot)
            ghostFlagsResult = result
            return result
        }

        /// **テスト専用の注入口**。呼び出し回数のカウンタは「cache を経由した呼び出し」しか
        /// 数えられないので、ある呼び手が cache 引数を丸ごと渡し忘れて生の関数を直呼びしても、
        /// 別の呼び手が後から同じ cache を正しく使えばカウンタは辻褄が合ってしまう
        /// (2026-08-12 に mutation-check で実際に2件すり抜けた)。**値の出所**を追う ——
        /// ここで明らかに間違った値を仕込み、応答にその値が現れるかで「本当にこのインスタンスを
        /// 読んだか」を確かめる。production コードはこのメソッドを呼ばない
        func primeGhostFlagsForTesting(_ value: [Int: String]) {
            ghostFlagsResult = value
        }

        func foldedGroups(_ snapshot: SnapshotResponse, flagging: [Int: String],
                          collapsingBulk: Bool) -> [String: Set<Int>] {
            if let cached = foldedGroupsResults[collapsingBulk] { return cached }
            foldedGroupsComputeCount += 1
            let result = SnapshotRenderer.foldedGroups(snapshot, flagging: flagging,
                                                       collapsingBulk: collapsingBulk)
            foldedGroupsResults[collapsingBulk] = result
            return result
        }

        /// `ambiguousLabelsNote` と `duplicateIDsNote` が**同じ**インスタンス(=同じ graded メモ)
        /// を共有するための入口。**snapshot はここに渡した1つに固定する**呼び出し規約
        /// (SelectorNaming.graded と同じ規約 — 別の木を渡すと ref が衝突する)
        func selectorNaming(_ snapshot: SnapshotResponse) -> SelectorNaming {
            if let namingInstance { return namingInstance }
            let created = SelectorNaming(snapshot)
            namingInstance = created
            return created
        }
    }

    // SelectorNaming / Durability の実体は FTCore.SelectorNaming / FTCore.Durability
    // (2026-08-15 に FTCore へ移設。StepExecutor の自己修復書き戻しも同じ判定を要るため)。
    // ここは呼び出し元・テストの綴りを変えないための typealias + 転送だけ
    // (RefGuard.swift が TapTargetGeometry/OcclusionGeometry へ転送しているのと同じ形)
    typealias SelectorNaming = FTCore.SelectorNaming
    typealias Durability = FTCore.Durability

    static func picksExactly(_ element: ElementInfo, with selector: String,
                             in snapshot: SnapshotResponse) -> Bool {
        SelectorNaming.picksExactly(element, with: selector, in: snapshot)
    }

    static func picksOnlyOne(_ element: ElementInfo, with selector: String,
                             in snapshot: SnapshotResponse) -> Bool {
        SelectorNaming.picksOnlyOne(element, with: selector, in: snapshot)
    }

    static func idCounts(in snapshot: SnapshotResponse) -> [String: Int] {
        SelectorNaming.idCounts(in: snapshot)
    }

    static func uniqueScopeID(for element: ElementInfo, in snapshot: SnapshotResponse,
                              idCounts precomputed: [String: Int]? = nil) -> String? {
        SelectorNaming.uniqueScopeID(for: element, in: snapshot, idCounts: precomputed)
    }

    static func scopedSelector(for element: ElementInfo, in snapshot: SnapshotResponse,
                               idCounts precomputed: [String: Int]? = nil) -> String? {
        SelectorNaming.scopedSelector(for: element, in: snapshot, idCounts: precomputed)
    }

    static func scopedSelector(scope: ElementInfo, for element: ElementInfo,
                               in snapshot: SnapshotResponse) -> String? {
        SelectorNaming.scopedSelector(scope: scope, for: element, in: snapshot)
    }

    /// 木が空(要素0)であること自体を言う。**一覧が空なのと「画面に何も無い」のは別**で、
    /// 実測(2026-08-13・Android Chrome の初回起動ダイアログを閉じた直後)では
    /// `screen: 1080x2424` の1行だけが返り、**遷移中である**という手掛かりがどこにも無かった。
    /// 木だけで判る事実なので目録に載る(NoteCatalog)。**次の一手まで書く** ——
    /// ここで読み手が撃つべきは撮り直しではなく `waitFor` 付きの1回
    static func emptyTreeNote(_ snapshot: SnapshotResponse) -> String {
        guard snapshot.elements.isEmpty else { return "" }
        return "note: the element list is empty — the app published no accessibility element at"
            + " all. That is almost always a screen mid-transition (or one that has not finished"
            + " loading), not an empty screen: read it again with ft_snapshot waitFor set to"
            + " something the destination has, and check ft_screenshot if it stays empty.\n"
    }

    /// **打ち切りは先頭でも言う**(2026-08-09)。`(+91 elements truncated)` は render の末尾に
    /// 1行出るだけで、120 行の一覧のいちばん下にあった —— 実測(Apple マップの経路プランナー)で
    /// **候補 211 件中 91 件が木から落ちて**いたのに、いちばん重い事実がいちばん読まれない位置に
    /// あった。打ち切りは描画の省略ではなく配列からの脱落なので、`waitFor` も `scrollTo` も
    /// 落ちた要素を一生探し続ける。
    ///
    /// **何が落ちたかはブリッジしか知らない**ので、申告があるときだけ内訳を添える
    /// (`SnapshotResponse.truncatedTiers`。無い = 旧ブリッジなら件数だけ)
    static func truncationNote(_ snapshot: SnapshotResponse) -> String {
        guard snapshot.truncatedCount > 0 else { return "" }
        let breakdown = snapshot.truncatedTiers.map { tiers -> String in
            let parts = SnapshotResponse.truncatedTierOrder.compactMap { tier -> String? in
                guard let count = tiers[tier.key], count > 0 else { return nil }
                return "\(count) \(tier.label)"
            }
            return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        } ?? ""
        // **逃げ道を必ず添える**(2026-08-12 のブラウザ監査): 従来の助言は「画面を狭くする」
        // だけで、web ページでは実行できない(シートも大きなリストも無い ——
        // 1ドキュメントぶんの要素が最初から全部載っている)。実測では tenki.jp の2週間天気で
        // **落ちた 179 件が全部 labelled = 表の本文**で、`ft_scroll_to` が2回で 101 秒を捨てた。
        // 順序は「上限を上げる」が先: 落ちた行がまさに読みたい物である確率が高い
        // 逃げ道の判定は `FTCore.SnapshotTruncation.remedy`(DSL と共有)。**天井まで来ていたら
        // 「上限を上げろ」と言わない** —— 言われたとおり上げても同じ木が返るのが最悪。
        // `remedy` が nil を返すのは `truncatedCount == 0` のときだけで、それは上のガードで
        // 既に排除済み。ここでは到達しない = 渡すのは Remedy の2ケースだけでよい
        guard let remedy = SnapshotTruncation.remedy(for: snapshot) else { return "" }
        let escape = truncationEscape(remedy, for: .note)
        return "note: \(snapshot.truncatedCount) element(s) were dropped by the snapshot limit"
            + "\(breakdown) — they are gone from the tree, not just hidden, so waitFor/ft_scroll_to"
            + " will never find them. \(escape)\(capHogNote(snapshot))\n"
    }

    /// 上限の外で bulk を送ったときの注記(61)。
    ///
    /// **「一覧が上限を超えているのは異常ではない」と言うためにある**: 読み手は
    /// `maxSnapshotElements` を知らないので、120 を超える一覧を見て木が壊れていると読む余地がある。
    /// 同時に「畳まれた群は枠を食っていない」= 打ち切りの原因ではないことも伝わる。
    /// **申告が無いブリッジ(旧版・Android)では黙る** —— 嘘の安心を出さない
    static func bulkExemptNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false) -> String {
        guard let count = snapshot.bulkExemptCount, count > 0 else { return "" }
        // **「無害」と読ませない**(2026-08-10): 元の文言は要素上限を守っていることしか言わず、
        // これらの行がコンテキストを消費している事実が伝わらなかった。
        // **満額は初回だけ**(2026-08-12 の監査。`abbreviated` は他の注記と同じ F-6 の仕組み):
        // 実体は木の1行に畳まれているのに、注記のほうが長いという逆転が毎回の応答で起きていた。
        // 伝えたい2点(枠を食っていない/出力は食う)は一度読めば足りる
        guard !abbreviated else {
            return "note: \(count) element(s) in folded same-id group(s)"
                + " (see the first snapshot's note).\n"
        }
        return "note: \(count) element(s) of large same-id group(s) are listed outside the"
            + " element limit — they did not crowd other elements out of the tree, but they do"
            + " add to this output; the rendering folds them (expandBulk lists them in full).\n"
    }

    /// 打ち切ったときだけ添える「枠を食っている当人」。
    ///
    /// **間引きの方針では直せないから、代わりに名指しする**(2026-08-09): 同一 id の地図 POI が
    /// 上限の過半を占めることは実際にある(実測: Apple マップの経路プランナーで 77/120)が、
    /// 「大きな同一 id 群を先に捨てる」は**リストの行にも同じだけ当たる**ので採れない
    /// (BridgeSnapshotThinning.bulkGroupMinimum の却下理由)。読み手にできる手は
    /// 「その群が出ない画面にする」= 地図を畳む・シートを閉じるなので、**どれが原因かだけ**言う
    static func capHogNote(_ snapshot: SnapshotResponse) -> String {
        var counts: [String: Int] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            counts[id, default: 0] += 1
        }
        guard let (id, count) = counts.max(by: { $0.value < $1.value }),
              count >= SnapshotRenderer.bulkGroupMinimum else { return "" }
        let share = count * 100 / max(1, snapshot.elements.count)
        return " #\(id) alone accounts for \(count) of the \(snapshot.elements.count) kept"
            + " element(s) (\(share)%) — collapsing whatever draws it (a map, a long list)"
            + " frees the most room."
    }

    /// キーボード下に隠れた操作対象。木からは判定できない(キーボードはスナップショットの対象外)
    /// ので、ブリッジ申告の `keyboardFrame` でだけ言える(判定は RefGuard.keyboardWarning と共有)。
    /// 実測(2026-08-08・iOS): キーボード下の候補行 ref タップが警告なしで顔文字キーに当たった。
    /// **見出しに出す座標は広げた実効矩形のまま**(申告のまま出すと判定と表示が食い違い、
    /// 読み手が検算できない)。**列挙は chrome 自身とその部分木を除く**(地球儀キー・変換候補
    /// バー等は覆っている側であり、覆われているとは言えない)
    static func keyboardCoverageNote(_ snapshot: SnapshotResponse) -> String {
        let occlusion = KeyboardOcclusion.resolve(
            reported: snapshot.keyboardFrame, in: snapshot.elements)
        guard let kb = occlusion.frame else { return "" }
        let header = "the soft keyboard covers"
            + " (\(Int(kb.x)),\(Int(kb.y)) \(Int(kb.width))x\(Int(kb.height)))"
        let covered = snapshot.elements.filter {
            RefGuard.interactiveTypes.contains($0.type) && occlusion.covers($0)
        }
        guard !covered.isEmpty else { return "note: \(header); nothing tappable is beneath it\n" }
        let listed = covered.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
            .joined(separator: " ")
        let more = covered.count > 8 ? " (+\(covered.count - 8) more)" : ""
        return "note: \(header). \(covered.count) listed element(s) are beneath it and a tap would"
            + " hit the keyboard instead: \(listed)\(more)\n"
    }

    /// ラベル付きだが極端に細い要素(掴めないほど狭い可能性)。
    /// 判定は RefGuard.isClippedSliver = DSL(TapTargetGeometry)と共有。
    /// 判定は要素自身の細さだけ(縁で切れたかは見ない)。
    /// **列挙は操作可能型(operableTypes)に限る**(2026-08-10): 文言が「タップに失敗するかも」
    /// なので、タップ対象にならない image/staticText に出すと空振りの注意になる(実測:
    /// 画面下端で 84x9 に切れた「IC 運賃」アイコン)。判定自体は共有のまま型を問わない
    static func sliverNote(_ snapshot: SnapshotResponse) -> String {
        let slivers = snapshot.elements.filter {
            RefGuard.isClippedSliver($0, screen: snapshot.screen)
                && BridgeSnapshotThinning.operableTypes.contains($0.type)
        }
        guard !slivers.isEmpty else { return "" }
        let listed = slivers.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
            .joined(separator: " ")
        let more = slivers.count > 8 ? " (+\(slivers.count - 8) more)" : ""
        return "note: \(slivers.count) element(s) are extremely thin with a label"
            + " (≤10 wide/tall, or ≤14 wide/tall and flush against the screen edge)"
            + " — the strip may be too thin to tap, whether clipped at an edge"
            + " or just narrow by design: \(listed)\(more)\n"
    }

    /// 曖昧と呼ぶ下限。**2**(2026-08-09 に3から下げた): 2件でも `tap("他のフィルタ")` は
    /// 一意に選べず、危険度は3件と変わらない。実測(Google マップの検索結果)では
    /// `"他のフィルタ"` が別 frame の2件あるのに黙っていた。
    /// 雑音は「入れ子の一本鎖」を除外して抑える(下記)
    static let ambiguousLabelMinimum = 2

    /// 群の全メンバーが index-based(`.indexed`)か「そもそも書けない」(`graded` が nil)で、
    /// かつ index-based なメンバーが**全員同じスコープ接頭辞**(`graded.selector` の最後の
    /// `" >> "` より前。無ければ空文字)を持つときだけ、代替セレクタの列挙を ref の列へ畳む。
    /// 1件でも `.stable` があれば nil(呼び手は従来の列挙描画へ落ちる)。
    /// **判定・整形の両方をここに閉じる**(呼び手が条件を自前で再実装しない)。
    /// 実測(2026-08-12 の Apple マップ監査): 同じ容器に並ぶ同型セルが10件あると、
    /// index 違いだけの代替セレクタ6行が並び、注記が本文より長くなっていた
    ///
    /// `gradedShown` は**明細描画と共有する**先頭 `ambiguousMatchesShown` 件の採番結果。
    /// 同じ要素を二度 `graded` に掛けない —— 実アプリ画面では1件の採番が候補の検証2周
    /// (`picksExactly`/`picksOnlyOne`)を払う(`SelectorNaming.typeLabelCounts` の doc 参照)。
    /// 打ち切りの外側は畳めるかの判定にしか使わないので、そこだけ遅延で引く。
    /// 空で呼べば全件を自分で引く(結果は同じ。共有しないぶん遅いだけ)
    static func compactGroupLine(label: String, matches: [ElementInfo],
                                 gradedShown: [(selector: String, durability: Durability)?] = [],
                                 naming: SelectorNaming, in snapshot: SnapshotResponse) -> String? {
        var scope: String?
        var anyIndexed = false
        for (offset, element) in matches.enumerated() {
            let cached = offset < gradedShown.count
                ? gradedShown[offset] : naming.graded(for: element, in: snapshot)
            guard let graded = cached else { continue }
            guard graded.durability == .indexed else { return nil }
            anyIndexed = true
            let prefix: String
            if let range = graded.selector.range(of: " >> ", options: .backwards) {
                prefix = String(graded.selector[..<range.lowerBound])
            } else {
                prefix = ""
            }
            // **スコープが割れたら畳まない**。2026-08-16 に「全員索引形なら畳めるはず」と
            // 緩めて実測したが、**撤回した** —— 固定コーパス 40 枚で減るのは 1,555B(最悪画面
            // `ios-maps_transit_steps_expanded` で 2,690→2,290)なのに対し、
            // 失うのは上のテストが witness を持つ識別情報そのもの(Google マップのタブ帯は
            // **どのタブの子かが祖先名にしか乗っていない**)。畳んだ瞬間に5件が区別できなくなる。
            // **再提案しない**(測ったうえで割に合わないと決めた)
            if let existing = scope {
                guard existing == prefix else { return nil }
            } else {
                scope = prefix
            }
        }
        let shownRefs = matches.prefix(ambiguousMatchesShown).map { "[\($0.ref)]" }
            .joined(separator: " ")
        let cut = matches.count > ambiguousMatchesShown
            ? " (+\(matches.count - ambiguousMatchesShown) more matches not shown)" : ""
        let reason: String
        if anyIndexed {
            let scopeClause = (scope?.isEmpty == false) ? "repeats inside \(scope!); " : ""
            reason = "\(scopeClause)every alternative is index-based, so tap by ref instead."
        } else {
            reason = "none of these have a selector on this screen; tap by ref instead."
        }
        return "  \(label) ×\(matches.count): \(shownRefs)\(cut) — \(reason)"
    }

    /// `ambiguousLabelsNote` と `duplicateIDsNote` が共有する描画本体。差分はグループ化キー
    /// (呼び出し側で `label` に整形済み — `"\"foo\""` か `"#foo"`)と3つの文言だけなので、
    /// ここは凡例ヘッダ・グループごとの明細・打ち切り行・`anyStable` フッタだけを持つ。
    /// **グループ化とフィルタは呼び出し側の責務のまま**(ここへ寄せない)
    /// `brief`(2026-08-16): **事実と群は出すが、要素ごとの代替セレクタの列挙だけ畳む**。
    /// A/B の計測用の口(`FT_MCP_NOTES_BRIEF` の宣言参照)で、既定は false = 従来どおり。
    /// **`abbreviated` とは畳む対象が違う** —— あちらはヘッダの凡例、こちらは明細。
    /// 実測(`ios-maps_transit_steps_expanded`)では、注記 3,621B のうち明細が主因で、
    /// 短縮形にしても 2,894B にしか下がらない
    private static func renderGroups(_ sortedGroups: [(label: String, matches: [ElementInfo])],
                                     naming: SelectorNaming, in snapshot: SnapshotResponse,
                                     fullHeader: String, shortHeader: String,
                                     overflowNoun: String, abbreviated: Bool,
                                     brief: Bool = false) -> String {
        guard !sortedGroups.isEmpty else { return "" }
        var lines: [String] = [abbreviated ? shortHeader : fullHeader]
        var anyStable = false
        if brief {
            // **既に畳まれている群には触らない**(2026-08-16 の実測で踏んだ): 全群が
            // `compactGroupLine` で畳まれる画面(セレクタが1つも書けない web の格子等)で
            // 末尾の総括を足すと、**畳んだはずの brief のほうが長くなる**(固定コーパス 40 枚中
            // 10 枚が負だった)。brief は full の**厳密な部分集合**でなければ、A/B が
            // 「明細の有無」ではなく「定型文の差」を測ってしまう
            var foldedAny = false
            for (label, matches) in sortedGroups.prefix(ambiguousLabelsShown) {
                let gradedShown = matches.prefix(ambiguousMatchesShown)
                    .map { naming.graded(for: $0, in: snapshot) }
                if let compact = compactGroupLine(label: label, matches: matches,
                                                  gradedShown: gradedShown, naming: naming,
                                                  in: snapshot) {
                    lines.append(compact)
                    continue
                }
                foldedAny = true
                let shownRefs = matches.prefix(ambiguousMatchesShown).map { "[\($0.ref)]" }
                    .joined(separator: " ")
                let cut = matches.count > ambiguousMatchesShown
                    ? " (+\(matches.count - ambiguousMatchesShown) more matches not shown)" : ""
                lines.append("  \(label) ×\(matches.count): \(shownRefs)\(cut)")
            }
            if sortedGroups.count > ambiguousLabelsShown {
                lines.append("  (+\(sortedGroups.count - ambiguousLabelsShown) more"
                    + " \(overflowNoun)(s) not shown — ft_snapshot again after narrowing the"
                    + " screen to see them)")
            }
            if foldedAny {
                lines.append("  Tap these by ref. To get a selector for one of them,"
                    + " ft_tap prints the selector it recommends for the element it hit.")
            }
            return lines.joined(separator: "\n") + "\n"
        }
        // **畳んだ行は既に「tap by ref instead」と言っている**(compactGroupLine)。全部が
        // 畳まれた回に末尾の総括まで出すと、同じ助言が N+1 回並ぶ(2026-08-12 の監査で実測:
        // Google マップの経路一覧で5群すべてが畳まれ、その下にもう一度同じ文が出ていた)
        var allCompact = true
        for (label, matches) in sortedGroups.prefix(ambiguousLabelsShown) {
            // **採番は1要素につき1回**: 畳めるかの判定と明細描画で二度引かない(compactGroupLine の doc)
            let gradedShown = matches.prefix(ambiguousMatchesShown)
                .map { naming.graded(for: $0, in: snapshot) }
            if let compact = compactGroupLine(label: label, matches: matches,
                                              gradedShown: gradedShown, naming: naming,
                                              in: snapshot) {
                lines.append(compact)
                continue
            }
            allCompact = false
            // **索引形も書き出す**。2026-08-16 に「索引形は最も弱い格付けなので ref だけにする」と
            // 削って実測したが、**撤回した** —— 固定コーパスで 3,401B(明細の 42%)を占める
            // 最大の塊ではあるが、**その長さの元凶であるスコープ接頭辞が識別情報そのもの**
            // (`#explore_tab_strip_button >> .other` と `#saved_tab_strip_button >> .other` は
            // 「どのタブの子か」だけが違う)。落とすと5件が区別できなくなる ——
            // compactGroupLine の同スコープ要求と**同じ理由で同じテストが捕まえる**。
            // **再提案しない**(2回試して2回とも同じ砦に当たった)
            let shown = zip(matches.prefix(ambiguousMatchesShown), gradedShown)
                .map { element, graded -> String in
                    guard let graded else { return "[\(element.ref)] —" }
                    if graded.durability == .stable { anyStable = true }
                    return "[\(element.ref)] \(graded.selector)\(graded.durability.mark)"
                }.joined(separator: " / ")
            let cut = matches.count > ambiguousMatchesShown
                ? " (+\(matches.count - ambiguousMatchesShown) more matches not shown)" : ""
            lines.append("  \(label) ×\(matches.count): \(shown)\(cut)")
        }
        if sortedGroups.count > ambiguousLabelsShown {
            lines.append("  (+\(sortedGroups.count - ambiguousLabelsShown) more \(overflowNoun)(s)"
                + " not shown — ft_snapshot again after narrowing the screen to see them)")
        }
        if !anyStable, !allCompact {
            lines.append("  none of the above have a stable selector on this screen —"
                + " prefer tapping by ref for these.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 同一ラベルが複数に一致するときの要約注記(欠陥⑩)。id の重複は別パッケージが
    /// 行内に `×N` として個別に出すので、こちらは**ラベルだけ**を扱う。
    /// 実測: 経路検索の候補一覧で「東京駅」が9件一致し、素のラベルでは一意に指せなかった
    /// `abbreviated`(F-6 の対象拡大・2026-08-10): 明細行(ラベルごとの候補列挙)と末尾の
    /// 「+N more」は既定と同じまま、ヘッダの凡例だけ「初出の注記を見よ」に圧縮する
    static func ambiguousLabelsNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false,
                                    brief: Bool = false,
                                    cache: SnapshotAnnotationCache? = nil) -> String {
        var groups: [String: [ElementInfo]] = [:]
        for e in snapshot.elements {
            // **ゼロ幅文字を落としてから数える**(2026-08-09)。一覧の行は
            // `SnapshotRenderer.renderElement` が除去済みの形で出すので、生ラベルのまま
            // 注記に出すと**同じラベルが1つの応答の中で2表記**になる(実測: Google マップの
            // `"​​埼京線​"`)。読み手はこれを別物と読む。数える側も揃える —— ゼロ幅の有無だけが
            // 違う2件は `FlowMatchMode.matches` では区別できず、実際に曖昧だから
            let label = SnapshotRenderer.displayText(e.label ?? "")
            guard !label.isEmpty else { continue }
            groups[label, default: []].append(e)
        }
        let ambiguous = groups
            .filter { $0.value.count >= ambiguousLabelMinimum && !isSingleChain($0.value, in: snapshot) }
            // **全員が飾りの葉なら列挙しない**(2026-08-10 の実アプリ監査): 地図 POI の
            // 「〜の路線」×3 のような群はセレクタの書き先にならないのに行を占めていた。
            // 1件でも操作対象・型付きが混じる群は従来どおり全員出す(片側だけ隠すと
            // ×N の数と明細が食い違う)。判定は bulk fold と同じ SnapshotRenderer.isDecorativeLeaf
            .filter { !$0.value.allSatisfy { SnapshotRenderer.isDecorativeLeaf($0, in: snapshot.elements) } }
            // **セレクタとして誰も書かないラベルは列挙しない**(2026-08-12 の実アプリ監査):
            // Google マップの経路詳細では区切りの `" · "` ×3 が代替セレクタ付きで注記の上位を
            // 占めていた。飾り葉フィルタ(上)は `type == "other"` 限定なので staticText の
            // 区切りは素通りする —— **あちらを広げない**(staticText を飾り扱いにすると
            // 見出しや値という正当なセレクタ対象まで消える)。ここで語の有無だけを見る。
            // **ただし操作可能要素が1つでも混じる群は残す**(上の飾り葉フィルタと同じ
            // 「1件でも実対象が混じれば全員出す」規律): '+'/'−' のような記号だけラベルの
            // ボタン群が丸ごと注記から消えていた
            .filter { !isSymbolOnlyLabel($0.key)
                || $0.value.contains { BridgeSnapshotThinning.operableTypes.contains($0.type) } }
            .sorted { groupPrecedes(key: $0.key, count: $0.value.count,
                                    otherKey: $1.key, otherCount: $1.value.count) }
        guard !ambiguous.isEmpty else { return "" }
        // **「一意に指せない」で終わらせない**(2026-08-09): MCP の出力はシナリオへ書く文字列を
        // 供給するためにあるので、代わりに書ける形まで出す。機構は `writableSelector` =
        // ft_tap の推奨セレクタ(E)と同じ実装
        // **cache 経由なら duplicateIDsNote と同じ SelectorNaming を共有する**(2026-08-12):
        // 両方の群に出る要素の graded を二重に検証しない
        let naming = cache?.selectorNaming(snapshot) ?? SelectorNaming(snapshot)
        return renderGroups(ambiguous.map { (label: "\"\($0.key)\"", matches: $0.value) },
                            naming: naming, in: snapshot,
                            fullHeader: "note: these labels match multiple elements, so a plain label"
                                + " selector cannot pick one uniquely. Write one of these instead"
                                + " (\"—\" = this element has no stable selector; use a labelled"
                                + " ancestor or a coordinate. \"~\" = index-based, so it breaks if"
                                + " the number of same-type siblings changes — usable, but the"
                                + " weakest of the three):",
                            shortHeader: "note: ambiguous labels — write one of these instead"
                                + " (legend in the first snapshot's note):",
                            overflowNoun: "ambiguous label", abbreviated: abbreviated, brief: brief)
    }

    /// 重複 id の要約注記。`#id` はこのツールが最も推奨するセレクタなので、行末の `×N` だけ
    /// では足りない —— 実測: 時刻ピッカーの「時」「分」が両方 `id=numberpicker_input` で、
    /// 読み手はどちらも `#numberpicker_input` で指せると誤読し、別の欄が操作された。
    /// 除外(isSingleChain)・上限・代替セレクタの出し方は ambiguousLabelsNote と**まったく同じ
    /// 仕組み**(SelectorNaming.graded)を使い回す —— 採番規則を2つ持たない。
    /// `abbreviated` はラベル版と同じ意味(F-6)
    static func duplicateIDsNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false,
                                 brief: Bool = false,
                                 cache: SnapshotAnnotationCache? = nil) -> String {
        var groups: [String: [ElementInfo]] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            groups[id, default: []].append(e)
        }
        let flags = cache?.ghostFlags(snapshot) ?? ghostFlags(snapshot)
        let bulkFolded = cache?.foldedGroups(snapshot, flagging: flags, collapsingBulk: true)
            ?? SnapshotRenderer.foldedGroups(snapshot, flagging: flags, collapsingBulk: true)
        let duplicated = groups
            .filter { $0.value.count >= ambiguousLabelMinimum && !isSingleChain($0.value, in: snapshot) }
            // **畳まれる群は列挙しない**。実測(Apple マップの経路プランナー): 地図ピンの
            // `#VKPointFeature ×165` が注記の先頭を占めていた —— 木では1行 + ラベル索引に
            // 畳まれている群で、`#id` の書き先にもならない。判定は render と同じ
            // `SnapshotRenderer.foldedGroups`(2つ目の「畳まれるか」を作らない)。
            // **expandBulk の値では切り替えない**: 個別列挙させたい回でも、165 行ぶんの
            // 「一意でない」は読み手の役に立たない
            .filter { bulkFolded[$0.key] == nil }
            .sorted { groupPrecedes(key: $0.key, count: $0.value.count,
                                    otherKey: $1.key, otherCount: $1.value.count) }
        guard !duplicated.isEmpty else { return "" }
        let naming = cache?.selectorNaming(snapshot) ?? SelectorNaming(snapshot)
        return renderGroups(duplicated.map { (label: "#\($0.key)", matches: $0.value) },
                            naming: naming, in: snapshot,
                            fullHeader: "note: these ids are shared by multiple elements, so a plain"
                                + " #id selector cannot pick one uniquely. Write one of these instead"
                                + " (\"—\" = this element has no stable selector; use a labelled"
                                + " ancestor or a coordinate. \"~\" = index-based, so it breaks if"
                                + " the number of same-type siblings changes — usable, but the"
                                + " weakest of the three):",
                            shortHeader: "note: duplicate ids — write one of these instead"
                                + " (legend in the first snapshot's note):",
                            overflowNoun: "duplicate id", abbreviated: abbreviated, brief: brief)
    }

    /// 注記に並べる群の順序。件数の多い順で、**同数タイは key の昇順**。
    /// タイを決めないと順序が Dictionary の反復順(プロセスごとに変わる)に委ねられ、
    /// 同じ木でも実行ごとに並びが入れ替わる —— `ambiguousLabelsShown` で打ち切るので
    /// **どの群が出るか**まで変わる。**同一プロセス内では再現しない**ので、テストは
    /// この比較関数を直接固定する(注記の文字列を2回比べても差は出ない)
    static func groupPrecedes(key: String, count: Int, otherKey: String, otherCount: Int) -> Bool {
        count == otherCount ? key < otherKey : count > otherCount
    }

    /// 曖昧ラベル注記に並べる上限。**打ち切ったことは必ず言う**(黙って切ると
    /// 「これで全部」と読まれる)
    static let ambiguousLabelsShown = 5
    static let ambiguousMatchesShown = 6

    /// 同じラベルの群が**入れ子の一本鎖**か(容器とその中身が同じラベルを名乗る形)。
    /// 下限を2へ下げると、`button "自宅、追加"` とその子 `#IconImage-TitleLabel-SubtitleLabel`
    /// のようなラッパー対が全部鳴る —— どちらを掴んでも同じものなので曖昧ではない。
    /// `RefGuard.stackedRefs` が同じ理由で使っている除外と同型
    /// **前提が崩れる形が1つある**(2026-08-14 に実機 Android の YouTube で実測): 祖先が
    /// **画面規模の面**で、子孫が**その中の小さな操作子**のとき、「どちらを掴んでも同じ」は
    /// 成り立たない。実測 —— 広告再生中の `clickable "Skip" #player_overlays (0,136 1080x1683)`
    /// と `clickable "Skip" #skip_ad_button (888,1555 192x132)` が同じラベルを名乗り、
    /// 前者は再生面のトグル・後者は広告スキップで**別の動作**なのに、一本鎖なので曖昧警告が
    /// 出ず、`tap 'Skip'` は木の順序で**面のほう**へ解決する。
    ///
    /// 条件は3つとも要る(**コーパス全数で誤検知0**を測ってから入れた):
    /// ⑴ 群のうち**2つ以上が操作可能型** —— 片方が staticText なら触れても祖先が受け取るので
    ///   無害(大小を `interactive` から採るので 75 件の誤検知はそこで消えている。この guard 自体は
    ///   不変条件の明示で、外しても振る舞いは変わらない = 変異では殺せない)
    /// ⑵ 大きいほうの**中心が小さいほうの外**にある(中に入るなら撃つ場所が同じ)
    /// ⑶ 大きいほうが**画面規模**(`fullScreenContainerAreaRatio`)—— これが無いと
    ///   `and-browser_weektable` の入れ子リンク(面積比2倍)が鳴る。実測の witness は
    ///   画面の 72% を占める再生面で、比は約 72 倍
    static func isSingleChain(_ group: [ElementInfo], in snapshot: SnapshotResponse) -> Bool {
        guard let first = group.first else { return true }
        let chain = TapTargetGeometry.lineage(of: first, in: snapshot.elements)
        guard group.allSatisfy({ chain.contains($0.ref) }) else { return false }
        return !chainHidesADifferentTarget(group, in: snapshot)
    }

    /// 一本鎖でも「どちらを掴んでも同じ」が成り立たない形か(`isSingleChain` の doc 参照)
    static func chainHidesADifferentTarget(_ group: [ElementInfo],
                                           in snapshot: SnapshotResponse) -> Bool {
        func area(_ e: ElementInfo) -> Double { e.frame.width * e.frame.height }
        let interactive = group.filter { TapTargetGeometry.interactiveTypes.contains($0.type) }
        guard interactive.count >= 2,
              let big = interactive.max(by: { area($0) < area($1) }),
              let small = interactive.min(by: { area($0) < area($1) })
        else { return false }
        let screenArea = snapshot.screen.width * snapshot.screen.height
        guard screenArea > 0,
              area(big) >= screenArea * TapTargetGeometry.fullScreenContainerAreaRatio
        else { return false }
        let cx = big.frame.x + big.frame.width / 2
        let cy = big.frame.y + big.frame.height / 2
        let centreInsideSmall = small.frame.x <= cx && cx <= small.frame.x + small.frame.width
            && small.frame.y <= cy && cy <= small.frame.y + small.frame.height
        return !centreInsideSmall
    }

    /// 語を1文字も含まないラベル(記号・約物・空白だけ)。曖昧ラベル一覧の唯一の除外判定。
    /// 判定は Unicode の英数字(L\* / N\*)で、仮名・漢字・ハングルも「語」に含まれる ——
    /// 日本語アプリのラベルを丸ごと落とさないため、`isLetter` ではなく alphanumerics を使う
    static func isSymbolOnlyLabel(_ label: String) -> Bool {
        !label.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// 座標ピンチの既定の半径 = 画面の短辺のこの割合。**画面相対**なのは、座標系が
    /// iOS=pt(短辺 402)/ Android=px(短辺 1080)で桁が違うため —— 固定値にすると
    /// 片方で指が開かず、もう片方で画面をはみ出す
    static let pinchRadiusScreenRatio = 0.22
    static let pinchRadiusFallback: Double = 100

    /// (x,y) を中心にした正方形の対象領域。**画面が分かるなら内側へ収める** ——
    /// 画面外へはみ出した指はタッチとして届かず、要求より小さいズームになる。
    /// 収め方は**中心を動かさず半径を縮める**(中心を寄せるとズームの支点が変わり、
    /// 「この地点を拡大したい」という指定そのものが崩れる)。縁ぎわの指定では
    /// 指の開きが小さくなるぶん倍率が出にくい
    static func pinchArea(x: Double, y: Double, radius: Double?, screen: FTRect?) -> FTRect {
        var r = radius ?? screen.map { min($0.width, $0.height) * pinchRadiusScreenRatio }
            ?? pinchRadiusFallback
        if let screen, screen.width > 0, screen.height > 0 {
            let room = [x - screen.x, screen.x + screen.width - x,
                        y - screen.y, screen.y + screen.height - y].min() ?? r
            r = max(1, min(r, room))
        }
        return FTRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
    }

    /// DSL の pressEnter(StepExecutor+Actions.swift)と値を共有 — FTCore.FocusWait が唯一の定義元
    static let focusWaitSeconds = FocusWait.waitSeconds
    static let focusPollSeconds = FocusWait.pollSeconds
}
