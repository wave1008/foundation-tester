// MCPServer+Hints.swift
// 木に添える注記・ヒント(ghost・類似ラベル・遮蔽・切り詰め等)。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore
import FTDSL

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
    static func visibleLabelsHint(_ snapshot: SnapshotResponse) -> String {
        var seen = Set<String>()
        var shown: [String] = []
        for e in snapshot.elements {
            // **ゼロ幅文字を落としてから出す**: ここから写したラベルは**見た目が正しいのに
            // 完全一致しない**(2026-08-07 実測。Google マップの発車案内で U+200B が21個
            // 漏れていた。木の描画側は除去済みで、ヒストだけ素通しだった)
            let cleaned = e.label.map(FlowMatchMode.normalizeInvisibleCharacters)
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

    static func ghostFlags(_ snapshot: SnapshotResponse) -> [Int: String] {
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
    static func ghostNote(_ snapshot: SnapshotResponse, collapsingBulk: Bool = true) -> String {
        let flagged = ghostFlags(snapshot)
        let folded = SnapshotRenderer.foldedGroups(snapshot, flagging: flagged,
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
        let quoted = (pager.value ?? pager.label).map { " \"\($0)\"" } ?? ""
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

    /// **scrollFrame を渡すべき当人**である ft_scroll_to にだけ出す、複数スクロール領域の注記
    /// (欠陥⑪)。`ScrollFrameCandidates.note` は ft_snapshot でしか呼ばれておらず、一番効く場所
    /// (scrollFrame: を渡すべき本人の失敗文・成功文)に届いていなかった。
    /// scrollFrame: を既に渡しているときは黙る(選んだ後なので不要)
    /// 木の前に置く注記は**1行で終える**(次の注記と同じ行に流れ込むと読み手が切れ目を失う)
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

    /// 「近い」の強さ。**部分文字列関係(どちらかがどちらかを含む・大文字小文字無視)が強、
    /// 編集距離だけの一致(短い語同士・6文字以下・距離2以下)が弱**。isSimilarText と
    /// similarLabelsHint の両方がここを唯一の判定源にする(2つ目の実装を作らない)
    enum SimilarityStrength { case strong, weak }

    static func similarityStrength(_ a: String, _ b: String) -> SimilarityStrength? {
        let la = a.lowercased(), lb = b.lowercased()
        guard la != lb else { return nil }
        if la.contains(lb) || lb.contains(la) { return .strong }
        guard la.count <= 6, lb.count <= 6 else { return nil }
        return Self.editDistance(la, lb) <= 2 ? .weak : nil
    }

    /// 「近い」の判定: ①どちらかがどちらかを部分文字列として含む(大文字小文字無視)
    /// ②短い文字列同士(6文字以下)なら編集距離2以下。②が無いと「経路」/「計画」のような
    /// 部分文字列関係の無い短い語の書き間違いを拾えない
    static func isSimilarText(_ a: String, _ b: String) -> Bool {
        Self.similarityStrength(a, b) != nil
    }

    /// waitFor が空振りしたとき、画面に**近い**ラベル/id を最大3件挙げる(2026-08-10)。
    /// 実測: 経路ボタンを `waitFor "経路"` と推測したら実ラベルは「計画」で5秒空振りした。
    /// **断定しない**(「これのことでは」とは書かない) —— 似ているというだけで、
    /// 別物を待っていた可能性を否定できる材料は無い
    ///
    /// **候補は全要素を見てからスコアで選ぶ**(2026-08-10 改訂)。旧版は文書順の先着3件を
    /// 返していたため、地図 POI のような装飾要素が短い CJK 語の緩い編集距離一致で枠を埋め、
    /// 実在した操作ボタンを1件も出せなかった(実測: 「南口」「北口」「1」が出て「計画」が出ない)。
    /// **装飾葉(bulk fold と同じ isDecorativeLeaf 判定)は候補プールから除く** —— 2つ目の
    /// 判定を書くと畳みと矛盾しかねない。残った候補は「強い一致 > 操作可能要素 > 文書順」で並べる
    static func similarLabelsHint(_ selectorText: String, in snapshot: SnapshotResponse) -> String {
        let locator = FTSelector.parse(selectorText).primary
        guard let raw = locator.label ?? locator.id,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let target = FlowMatchMode.normalizeInvisibleCharacters(raw)

        struct Candidate {
            let display: String
            let strength: SimilarityStrength
            let operable: Bool
            let order: Int
        }
        func isBetter(_ a: Candidate, _ b: Candidate) -> Bool {
            if (a.strength == .strong) != (b.strength == .strong) { return a.strength == .strong }
            if a.operable != b.operable { return a.operable }
            return a.order < b.order
        }
        var best: [String: Candidate] = [:]
        func consider(key: String, display: String, strength: SimilarityStrength,
                      operable: Bool, order: Int) {
            let candidate = Candidate(display: display, strength: strength,
                                      operable: operable, order: order)
            if let existing = best[key], !isBetter(candidate, existing) { return }
            best[key] = candidate
        }

        for (order, element) in snapshot.elements.enumerated() {
            guard !SnapshotRenderer.isDecorativeLeaf(element, in: snapshot.elements) else { continue }
            let operable = BridgeSnapshotThinning.operableTypes.contains(element.type)
                || SnapshotRenderer.textInputTypes.contains(element.type)
            if let label = element.label {
                let candidate = FlowMatchMode.normalizeInvisibleCharacters(label)
                if !candidate.isEmpty, let strength = Self.similarityStrength(target, candidate) {
                    consider(key: candidate, display: "\"\(candidate)\"", strength: strength,
                            operable: operable, order: order)
                }
            }
            if let id = element.identifier, !id.isEmpty,
               let strength = Self.similarityStrength(target, id) {
                consider(key: "#" + id, display: "#\(id)", strength: strength,
                        operable: operable, order: order)
            }
        }
        let top = best.values.sorted(by: isBetter).prefix(3)
        guard !top.isEmpty else { return "" }
        return " note: similar labels on screen: \(top.map(\.display).joined(separator: ", "))."
    }

    /// 素朴な編集距離(挿入・削除・置換を1コストずつ)。短い文字列(≤6)にしか使わない前提の
    /// O(n*m) 実装で十分 — 長い文字列にまで広げるならもっと速いものへ替える
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i]
            for j in 1...y.count {
                current.append(x[i - 1] == y[j - 1] ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1]))
            }
            previous = current
        }
        return previous.last ?? 0
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
    /// FTCore 側に同趣旨(`StepExecutor+Assert.truncationHint`)があるが internal で呼べないため、
    /// 文言だけ揃えてこちらに複製する
    static func truncationHint(_ snapshot: SnapshotResponse) -> String {
        guard snapshot.truncatedCount > 0 else { return "" }
        return " (the tree was truncated at \(snapshot.elements.count) elements;"
            + " \(snapshot.truncatedCount) more were omitted — the element you are looking for"
            + " may be among them)"
    }

    /// **ラベルも id も無い clickable**の注記(欠陥⑨)。座標か ref でしか指定できず、
    /// シナリオでは安定したセレクタを書けないことを伝える。実測: 経路の移動手段タブ(アイコンのみ)
    /// が id もラベルも無い `clickable` として出て、書ける手段が何も無いことに気付けなかった
    /// `abbreviated`(F-6 の対象拡大・2026-08-10): 明細(`listed`)は既定と同じまま、
    /// 冒頭の長い advice だけ「初出の注記を見よ」に圧縮する。呼び手は once 経由(instance の
    /// `unlabeledClickablesNote(_:)` ラッパ)で使い分ける
    static func unlabeledClickablesNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false)
        -> String {
        let unlabeled = snapshot.elements.filter {
            $0.type == "clickable" && ($0.identifier ?? "").isEmpty && ($0.label ?? "").isEmpty
        }
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

    /// **シナリオにそのまま書けるセレクタ**を1つ決める。書けないときは nil ——
    /// 「無い」を黙らず言うのが要点で、ref はセッション限りの番号なのでシナリオには書けない。
    ///
    /// 優先順(B-1・E-1 で共有。**2つ目の実装を作らない**):
    ///   1. 画面で一意な `#id` —— いちばん短く、他の画面でも通りやすい
    ///   2. 画面で一意なラベル —— id を持たない要素でも書ける
    ///   3. スコープ記法 `#容器 >> .型[n]` —— id を持つ一意な祖先があるときだけ
    ///   4. それ以外は nil
    ///
    /// **一意性は「今撮った画面の中で」**。他の画面まで保証はできないので、そこは
    /// ft_dry_run(SelectorInventory の突き合わせ)と実行に委ねる
    /// セレクタの壊れにくさ。**綴りからは判定しない**(2026-08-10)。
    /// 位置で選ぶ式は必ずしも `[n]` を含まない —— `#容器 >> .clickable` は「容器の中の最初の
    /// clickable」で、`[1]` を書いたのと同じ意味だが綴りに添字が出ない。
    /// 綴りで見ると**この形だけが「安定」と誤って印無しになる**ので、
    /// どの候補から採ったか(id/ラベル か スコープ記法 か)を持ち回る
    enum Durability {
        /// `#id` / 一意ラベル。木が変わっても指し続ける
        case stable
        /// `#container >> .type[n]`。同じ型の兄弟が1つ増減すると別要素を指す
        case indexed

        /// 一覧に添える印。安定側は無印(印が付くのは注意が要るものだけ、が読みやすい)
        var mark: String { self == .indexed ? "~" : "" }

        /// 1つだけ返すとき(ft_tap の戻り値)の但し書き
        var caution: String {
            self == .indexed
                ? " — index-based, so it breaks if the number of same-type siblings changes;"
                    + " prefer having the app expose an id"
                : ""
        }
    }

    struct SelectorNaming {
        private let idCounts: [String: Int]
        private let labelCounts: [String: Int]
        /// 「型 × ラベル」の出現数。**候補を組む前のゲート**で、これが 1 のときだけ
        /// `.型&&ラベル` を試す —— 数え上げは木1周(O(N))で済むのに対し、候補の検証は
        /// `matchDetailed` + `resolvedCandidates` の2周を候補ごとに払う。
        /// 入れ忘れると注記1本の生成が実アプリ画面で 29ms → 116ms になる(2026-08-12 に実測)
        private let typeLabelCounts: [String: Int]

        init(_ snapshot: SnapshotResponse) {
            var ids: [String: Int] = [:]
            var labels: [String: Int] = [:]
            var typeLabels: [String: Int] = [:]
            for e in snapshot.elements {
                if let id = e.identifier, !id.isEmpty { ids[id, default: 0] += 1 }
                let label = FlowMatchMode.normalizeInvisibleCharacters(e.label ?? "")
                if !label.isEmpty {
                    labels[label, default: 0] += 1
                    typeLabels[Self.typeLabelKey(e.type, label), default: 0] += 1
                }
            }
            idCounts = ids
            labelCounts = labels
            typeLabelCounts = typeLabels
        }

        /// 型名とラベルの区切りは**要素の文字に現れない値**を使う(型名に混ざると別の組を
        /// 同一視する)
        static func typeLabelKey(_ type: String, _ label: String) -> String {
            "\(type)\u{0}\(label)"
        }

        /// スコープの中でそのラベル(と 型×ラベル)が何件あるか。**スコープを跨いで数えない**
        /// のがここの要点 —— 画面全体では重複するラベルでも、容器の中では一意なことが多い。
        /// 走査は候補を組む直前の1回だけで、`uniqueScopeID` が nil を返す要素では走らない
        static func labelCountsInScope(_ scopeID: String, of element: ElementInfo,
                                       in snapshot: SnapshotResponse,
                                       label: String) -> (plain: Int, typed: Int)? {
            guard let scope = snapshot.elements.first(where: { $0.identifier == scopeID })
            else { return nil }
            var plain = 0, typed = 0
            for e in StepExecutor.descendants(of: scope, in: snapshot.elements)
            where FlowMatchMode.normalizeInvisibleCharacters(e.label ?? "") == label {
                plain += 1
                if e.type == element.type { typed += 1 }
            }
            return (plain, typed)
        }

        /// ラベルを素で書くと記法として読まれてしまう形か。`=` 逃がしはこのときだけ足す ——
        /// 常に両方を候補に入れると、**当たる方が先に通るので結果は同じなのに検証を2倍払う**
        /// 判定は2種類ある。**片方だけでは足りない**:
        /// ① 意味が変わる形(`#`/`.` 始まり・演算子)—— 往復はするが別のフィルタとして読まれる
        /// ② 綴りが往復しない形(前後の空白など)—— 意味は同じだが印字とコードが食い違う
        ///    (実測: `and-place_expanded` にラベルが空白2文字だけの要素がある)
        static func needsEscaping(_ label: String) -> Bool {
            guard let first = label.first else { return false }
            if "#.=!*".contains(first) { return true }
            if ["&&", ">>", "||", "[", "]", "(", ")", "|"].contains(where: label.contains) {
                return true
            }
            // **`asWritten` は使わない**: あれは空になったとき元の文字列へ落とすので、
            // 「空へ潰れる = いちばん往復しない形」を素通りさせる(実測: ラベルが
            // `" · "` や空白だけの要素)。ここは素の往復をそのまま見る
            let parsed = FTSelector.parse(label)
            return FTSelector.serialize(primary: parsed.primary, fallbacks: parsed.fallbacks) != label
        }

        /// **勧める前に自分で引いてみる**(2026-08-09。実アプリ 18 枚へ当てて発覚): 候補を
        /// 組み立てただけでは書けているか分からない —— ラベルを `"…"` で囲んで出していた版は
        /// 引用符ごと literal になって**1件も当たらなかった**。記法の綴じ(先頭が `#`/`.`、
        /// `>>` や `||` を含む等)は場合分けで潰しきれないので、DSL 本体で解決して
        /// **当人が返ることを確かめてから**返す
        func selector(for element: ElementInfo, in snapshot: SnapshotResponse) -> String? {
            graded(for: element, in: snapshot)?.selector
        }

        /// セレクタと**その耐久性**。「書ける」と「壊れにくい」は別物で、同じ一覧に混ぜると
        /// 生成器は先頭を採るだけになる(2026-08-10)。`#id` と一意ラベルは木が変わっても
        /// 指し続けるが、`#container >> .type[n]` の `[n]` は**同じ型の兄弟が1つ増減しただけで
        /// 別要素を指す**ので、シナリオに書くと静かに壊れる
        func graded(for element: ElementInfo,
                    in snapshot: SnapshotResponse) -> (selector: String, durability: Durability)? {
            // **検査は耐久性で選ぶ**: `.stable` は「位置に依存しない」という意味なので、
            // 候補が2件以上あってはならない(先頭一致で通してしまうと、群の1件目にだけ
            // 嘘の助言が出る)。`.indexed` は添字で1つに絞る式なので `picksExactly` が正しい
            // —— `resolvedCandidates` は添字を適用する前の列で、必ず複数になる
            func holds(_ selector: String, _ durability: Durability) -> Bool {
                durability == .indexed
                    ? MCPServer.picksExactly(element, with: selector, in: snapshot)
                    : MCPServer.picksOnlyOne(element, with: selector, in: snapshot)
            }
            for candidate in candidates(for: element, in: snapshot)
            where holds(candidate.selector, candidate.durability) {
                // **勧める形と書かれる形を揃える**(2026-08-10): 下書きは locator を
                // `FTSelector.serialize` で書き戻すので、`[1]` のような冗長な節はそこで落ちる。
                // 勧めた文字列をそのまま出すと「注記は `.clickable[1]`、コードは `.clickable`」
                // という食い違いになり、1箇所で決める意味が無くなる
                let written = MCPServer.asWritten(candidate.selector)
                let agreed = holds(written, candidate.durability)
                return (agreed ? written : candidate.selector, candidate.durability)
            }
            return nil
        }

        /// 優先順に並べた候補(採否は graded(for:in:) が実際に引いて決める)。
        /// **耐久性は候補の出所で決める** —— 綴りを見ても分からない(Durability のコメント参照)
        private func candidates(for element: ElementInfo,
                                in snapshot: SnapshotResponse)
            -> [(selector: String, durability: Durability)] {
            var out: [(selector: String, durability: Durability)] = []
            if let id = element.identifier, !id.isEmpty, idCounts[id] == 1 {
                out.append(("#\(id)", .stable))
            }
            // **切り詰め表示になるラベルは候補にしない**: 40字超は一覧に "…" 付きで出るので、
            // 読み手が写した完全一致は必ず外れる(SnapshotRenderer.truncatedLabelNote と同じ理由)
            let label = FlowMatchMode.normalizeInvisibleCharacters(element.label ?? "")
            let writableLabel = !label.isEmpty && label.count <= SnapshotRenderer.labelDisplayLimit
            // **素の形を先に置く**(順序を入れ替えない): `asWritten` は逃がしを外した形を返すので、
            // 逃がし形を先に採ると「勧めた文字列」と「下書きに書かれる文字列」が食い違う
            // (実測: ラベル `" ·"` で `= ·` を先に置いたら、注記は `" ·"`・コードは `"·"` になった)。
            // 逃がしは**素で書けない形のときだけ**後ろに足す —— 常に両方入れると、
            // 当たる方が先に通るので結果は同じなのに候補の検証を2倍払う
            let labelForms = Self.needsEscaping(label) ? [label, "=\(label)"] : [label]
            if writableLabel, labelCounts[label] == 1 {
                out += labelForms.map { ($0, .stable) }
            }
            // **ラベルが重複していても、まず絞ってから索引に落とす**(2026-08-12 の実アプリ監査)。
            // ここが無かった版は「一意な id も一意なラベルも無い」を即 `#容器 >> .型[n]` に
            // 落としていた —— 実測(Google マップの検索候補)では `#typed_suggest_container >>
            // .clickable[3]` しか書けず、**候補の件数が変わると別の駅を選ぶ**。
            // `&&`(AND 合成)と `>>`(スコープ)は DSL の記法にあり、どちらも位置に依存しない。
            // **既存の提案は動かさない** —— 上の `#id` / 一意ラベルより後、索引形より前に置く
            // **数え上げで足切りしてから検証する**: 候補1つの検証は木2周(`matchDetailed` と
            // `resolvedCandidates`)で、当たらない候補まで並べると注記の生成が実アプリ画面で
            // 4倍になる(2026-08-12 に実測して入れ直した)。数え上げは init の1周で済む
            if writableLabel {
                if typeLabelCounts[Self.typeLabelKey(element.type, label)] == 1 {
                    out += labelForms.map { (".\(element.type)&&\($0)", .stable) }
                }
                if let scope = MCPServer.uniqueScopeID(for: element, in: snapshot),
                   let inScope = Self.labelCountsInScope(scope, of: element, in: snapshot, label: label) {
                    if inScope.plain == 1 {
                        out += labelForms.map { ("#\(scope) >> \($0)", .stable) }
                    }
                    if inScope.typed == 1 {
                        out += labelForms.map { ("#\(scope) >> .\(element.type)&&\($0)", .stable) }
                    }
                }
            }
            if let scoped = MCPServer.scopedSelector(for: element, in: snapshot) {
                out.append((scoped, .indexed))
            }
            return out
        }
    }

    /// このセレクタが**その要素ただ1つ**を選ぶか。判定は DSL 本体(`matchDetailed`)に委ねる ——
    /// `resolvedCandidates` は `[n]` を適用する前の候補列なので、ここで使うと
    /// 添字付きのスコープ記法を「曖昧」と誤判定する。
    /// フォールバック(`a||b`)を含む式は「1つを選ぶ」と言えないので採らない
    static func picksExactly(_ element: ElementInfo, with selector: String,
                             in snapshot: SnapshotResponse) -> Bool {
        let parsed = FTSelector.parse(selector)
        guard parsed.fallbacks.isEmpty else { return false }
        return StepExecutor.matchDetailed(parsed.primary,
                                          elements: snapshot.elements)?.0.ref == element.ref
    }

    /// **その要素**を選び、かつ**候補が1件しかない**か。`picksExactly` は `matchDetailed` の
    /// 先頭一致を見るだけなので、**曖昧な式でも先頭の要素に対しては true を返す** ——
    /// 添字なしの式(`.型&&ラベル` など)をそれだけで採ると、群の1件目にだけ
    /// 「一意に指せる」と嘘の助言を出す(2026-08-12 に `MCPWritableSelectorTests` が捕まえた)。
    /// **`[n]` を含む式には使わない**: `resolvedCandidates` は添字を適用する前の候補列なので、
    /// 添字付きのスコープ記法を「曖昧」と誤判定する(`picksExactly` のコメント参照)
    static func picksOnlyOne(_ element: ElementInfo, with selector: String,
                             in snapshot: SnapshotResponse) -> Bool {
        guard picksExactly(element, with: selector, in: snapshot) else { return false }
        let parsed = FTSelector.parse(selector)
        return StepExecutor.resolvedCandidates(parsed.primary, elements: snapshot.elements)?.count == 1
    }

    /// 画面内の id 出現回数。**uniqueScopeID とページャ案内(pagerScrollFrameHint)が共有する
    /// 唯一の数え方** —— 別々に書くと「一意」の定義がずれる
    static func idCounts(in snapshot: SnapshotResponse) -> [String: Int] {
        var counts: [String: Int] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            counts[id, default: 0] += 1
        }
        return counts
    }

    /// スコープに使える最も近い祖先の id。**条件は3つ**: ① id を持つ祖先が居る
    /// ② **その id が画面で一意**(重複していると `#recycler_view` のように4つある画面で
    /// 別の容器を掴む) ③ **その祖先の frame が対象を包含する**。`TapTargetGeometry.ancestors` は
    /// preorder+depth だけから祖先を再構成し frame も親ポインタも見ないので、木が間引かれると
    /// 実際の親より手前に並ぶ叔父を祖先と誤認しうる(実測: Google マップの時刻ピッカーで、
    /// 分の入力欄の祖先として無関係な `#divider`(「:」1文字)が選ばれた)。
    /// `#容器 >> …` を組む者はすべてここを通す —— スコープの規則を2箇所に持つと、
    /// `.型[n]` 版とラベル版で別の容器を指しはじめる
    static func uniqueScopeID(for element: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        let counts = idCounts(in: snapshot)
        return TapTargetGeometry.ancestors(of: element, in: snapshot.elements)
            .first { ancestor in
                guard let id = ancestor.identifier, !id.isEmpty, counts[id] == 1,
                      ancestor.frame.width > 0, ancestor.frame.height > 0 else { return false }
                return TapTargetGeometry.contains(ancestor.frame, element.frame)
            }?.identifier
    }

    /// `#container >> .type[n]` を組み立てる。**書けないときは nil**(嘘の助言を出さない)。
    ///
    /// 条件は `uniqueScopeID` に委ねる(id の一意性・frame の包含)。
    /// 添字はスコープ内・同じ型の中での順番で、記法は **1 オリジン**(FlowLocator.index の規約)
    static func scopedSelector(for element: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        guard let scopeID = uniqueScopeID(for: element, in: snapshot),
              let scope = snapshot.elements.first(where: { $0.identifier == scopeID })
        else { return nil }
        let siblings = StepExecutor.descendants(of: scope, in: snapshot.elements)
            .filter { $0.type == element.type }
        guard let position = siblings.firstIndex(where: { $0.ref == element.ref }) else { return nil }
        return "#\(scopeID) >> .\(element.type)[\(position + 1)]"
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
        return "note: \(snapshot.truncatedCount) element(s) were dropped by the snapshot limit"
            + "\(breakdown) — they are gone from the tree, not just hidden, so waitFor/ft_scroll_to"
            + " will never find them. Narrow the screen (close a sheet, scroll a big list away)"
            + " or work from what is listed.\(capHogNote(snapshot))\n"
    }

    /// 上限の外で bulk を送ったときの注記(61)。
    ///
    /// **「一覧が上限を超えているのは異常ではない」と言うためにある**: 読み手は
    /// `maxSnapshotElements` を知らないので、120 を超える一覧を見て木が壊れていると読む余地がある。
    /// 同時に「畳まれた群は枠を食っていない」= 打ち切りの原因ではないことも伝わる。
    /// **申告が無いブリッジ(旧版・Android)では黙る** —— 嘘の安心を出さない
    static func bulkExemptNote(_ snapshot: SnapshotResponse) -> String {
        guard let count = snapshot.bulkExemptCount, count > 0 else { return "" }
        // **「無害」と読ませない**(2026-08-10): 元の文言は要素上限を守っていることしか言わず、
        // これらの行がコンテキストを消費している事実が伝わらなかった
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
    /// 実測(2026-08-08・iOS): キーボード下の候補行 ref タップが警告なしで顔文字キーに当たった
    static func keyboardCoverageNote(_ snapshot: SnapshotResponse) -> String {
        guard let kb = snapshot.keyboardFrame else { return "" }
        let header = "the soft keyboard covers"
            + " (\(Int(kb.x)),\(Int(kb.y)) \(Int(kb.width))x\(Int(kb.height)))"
        let covered = snapshot.elements.filter {
            RefGuard.interactiveTypes.contains($0.type)
                && TapTargetGeometry.keyboardCoveredAdvisory($0, keyboardFrame: kb) != nil
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

    /// 同一ラベルが複数に一致するときの要約注記(欠陥⑩)。id の重複は別パッケージが
    /// 行内に `×N` として個別に出すので、こちらは**ラベルだけ**を扱う。
    /// 実測: 経路検索の候補一覧で「東京駅」が9件一致し、素のラベルでは一意に指せなかった
    /// `abbreviated`(F-6 の対象拡大・2026-08-10): 明細行(ラベルごとの候補列挙)と末尾の
    /// 「+N more」は既定と同じまま、ヘッダの凡例だけ「初出の注記を見よ」に圧縮する
    static func ambiguousLabelsNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false)
        -> String {
        var groups: [String: [ElementInfo]] = [:]
        for e in snapshot.elements {
            // **ゼロ幅文字を落としてから数える**(2026-08-09)。一覧の行は
            // `SnapshotRenderer.renderElement` が除去済みの形で出すので、生ラベルのまま
            // 注記に出すと**同じラベルが1つの応答の中で2表記**になる(実測: Google マップの
            // `"​​埼京線​"`)。読み手はこれを別物と読む。数える側も揃える —— ゼロ幅の有無だけが
            // 違う2件は `FlowMatchMode.matches` では区別できず、実際に曖昧だから
            let label = FlowMatchMode.normalizeInvisibleCharacters(e.label ?? "")
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
            // 見出しや値という正当なセレクタ対象まで消える)。ここで語の有無だけを見る
            .filter { !isSymbolOnlyLabel($0.key) }
            .sorted { $0.value.count > $1.value.count }
        guard !ambiguous.isEmpty else { return "" }
        // **「一意に指せない」で終わらせない**(2026-08-09): MCP の出力はシナリオへ書く文字列を
        // 供給するためにあるので、代わりに書ける形まで出す。機構は `writableSelector` =
        // ft_tap の推奨セレクタ(E)と同じ実装
        let naming = SelectorNaming(snapshot)
        var lines: [String] = [abbreviated
            ? "note: ambiguous labels — write one of these instead (legend in the first"
                + " snapshot's note):"
            : "note: these labels match multiple elements, so a plain label"
                + " selector cannot pick one uniquely. Write one of these instead"
                + " (\"—\" = this element has no stable selector; use a labelled ancestor or"
                + " a coordinate. \"~\" = index-based, so it breaks if the number of same-type"
                + " siblings changes — usable, but the weakest of the three):"]
        var anyStable = false
        for (label, matches) in ambiguous.prefix(ambiguousLabelsShown) {
            let shown = matches.prefix(ambiguousMatchesShown).map { element -> String in
                guard let graded = naming.graded(for: element, in: snapshot) else {
                    return "[\(element.ref)] —"
                }
                if graded.durability == .stable { anyStable = true }
                return "[\(element.ref)] \(graded.selector)\(graded.durability.mark)"
            }.joined(separator: " / ")
            let cut = matches.count > ambiguousMatchesShown
                ? " (+\(matches.count - ambiguousMatchesShown) more matches not shown)" : ""
            lines.append("  \"\(label)\" ×\(matches.count): \(shown)\(cut)")
        }
        if ambiguous.count > ambiguousLabelsShown {
            lines.append("  (+\(ambiguous.count - ambiguousLabelsShown) more ambiguous label(s)"
                + " not shown — ft_snapshot again after narrowing the screen to see them)")
        }
        if !anyStable {
            lines.append("  none of the above have a stable selector on this screen —"
                + " prefer tapping by ref for these.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 重複 id の要約注記。`#id` はこのツールが最も推奨するセレクタなので、行末の `×N` だけ
    /// では足りない —— 実測: 時刻ピッカーの「時」「分」が両方 `id=numberpicker_input` で、
    /// 読み手はどちらも `#numberpicker_input` で指せると誤読し、別の欄が操作された。
    /// 除外(isSingleChain)・上限・代替セレクタの出し方は ambiguousLabelsNote と**まったく同じ
    /// 仕組み**(SelectorNaming.graded)を使い回す —— 採番規則を2つ持たない。
    /// `abbreviated` はラベル版と同じ意味(F-6)
    static func duplicateIDsNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false) -> String {
        var groups: [String: [ElementInfo]] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            groups[id, default: []].append(e)
        }
        let bulkFolded = SnapshotRenderer.foldedGroups(snapshot, flagging: ghostFlags(snapshot),
                                                       collapsingBulk: true)
        let duplicated = groups
            .filter { $0.value.count >= ambiguousLabelMinimum && !isSingleChain($0.value, in: snapshot) }
            // **畳まれる群は列挙しない**。実測(Apple マップの経路プランナー): 地図ピンの
            // `#VKPointFeature ×165` が注記の先頭を占めていた —— 木では1行 + ラベル索引に
            // 畳まれている群で、`#id` の書き先にもならない。判定は render と同じ
            // `SnapshotRenderer.foldedGroups`(2つ目の「畳まれるか」を作らない)。
            // **expandBulk の値では切り替えない**: 個別列挙させたい回でも、165 行ぶんの
            // 「一意でない」は読み手の役に立たない
            .filter { bulkFolded[$0.key] == nil }
            .sorted { $0.value.count > $1.value.count }
        guard !duplicated.isEmpty else { return "" }
        let naming = SelectorNaming(snapshot)
        var lines: [String] = [abbreviated
            ? "note: duplicate ids — write one of these instead (legend in the first"
                + " snapshot's note):"
            : "note: these ids are shared by multiple elements, so a plain #id"
                + " selector cannot pick one uniquely. Write one of these instead"
                + " (\"—\" = this element has no stable selector; use a labelled ancestor or"
                + " a coordinate. \"~\" = index-based, so it breaks if the number of same-type"
                + " siblings changes — usable, but the weakest of the three):"]
        var anyStable = false
        for (id, matches) in duplicated.prefix(ambiguousLabelsShown) {
            let shown = matches.prefix(ambiguousMatchesShown).map { element -> String in
                guard let graded = naming.graded(for: element, in: snapshot) else {
                    return "[\(element.ref)] —"
                }
                if graded.durability == .stable { anyStable = true }
                return "[\(element.ref)] \(graded.selector)\(graded.durability.mark)"
            }.joined(separator: " / ")
            let cut = matches.count > ambiguousMatchesShown
                ? " (+\(matches.count - ambiguousMatchesShown) more matches not shown)" : ""
            lines.append("  #\(id) ×\(matches.count): \(shown)\(cut)")
        }
        if duplicated.count > ambiguousLabelsShown {
            lines.append("  (+\(duplicated.count - ambiguousLabelsShown) more duplicate id(s)"
                + " not shown — ft_snapshot again after narrowing the screen to see them)")
        }
        if !anyStable {
            lines.append("  none of the above have a stable selector on this screen —"
                + " prefer tapping by ref for these.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 曖昧ラベル注記に並べる上限。**打ち切ったことは必ず言う**(黙って切ると
    /// 「これで全部」と読まれる)
    static let ambiguousLabelsShown = 5
    static let ambiguousMatchesShown = 6

    /// 同じラベルの群が**入れ子の一本鎖**か(容器とその中身が同じラベルを名乗る形)。
    /// 下限を2へ下げると、`button "自宅、追加"` とその子 `#IconImage-TitleLabel-SubtitleLabel`
    /// のようなラッパー対が全部鳴る —— どちらを掴んでも同じものなので曖昧ではない。
    /// `RefGuard.stackedRefs` が同じ理由で使っている除外と同型
    static func isSingleChain(_ group: [ElementInfo], in snapshot: SnapshotResponse) -> Bool {
        guard let first = group.first else { return true }
        let chain = TapTargetGeometry.lineage(of: first, in: snapshot.elements)
        return group.allSatisfy { chain.contains($0.ref) }
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
