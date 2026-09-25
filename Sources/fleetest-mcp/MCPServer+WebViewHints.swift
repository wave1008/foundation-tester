// MCPServer+WebViewHints.swift
// WebView・ブラウザ・グリッド・アドレス欄・URL 片・無ラベルのクリック可能要素の注記。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// WebView の中に**要素が1つも無い縦帯**がある = 木がその部分を落としている疑い。
    ///
    /// なぜ要るか(Android の Chrome で実測): Chrome は web コンテンツの
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
    /// (jma.go.jp を Android Chrome で実測)。
    ///
    /// なぜ要るか: `webViewGapNote` は webView 容器の**内側**しか測れず、`emptyTreeNote` は
    /// `elements.isEmpty` の完全一致でしか発火しない。Chrome が自分の chrome(ツールバー・
    /// アドレス欄)しか公開せず、ページ本体を一切木に出さない画面は、この2本のどちらの網にも
    /// 掛からずに黙って通り抜ける —— 実測(and-browser_jma_notree)は要素19件が全部ブラウザ
    /// chrome で、画面の 88.6%(unrepresentedScreenFraction)が空白のまま報告されていた。
    ///
    /// **既定が a11y になったので、この注記は役目を終えた**(ユーザー決定で反転)。
    /// a11y から来ているのは**正常**になり、言うことが行動に繋がらない
    /// (足りないときは `missingPageContentNote` が「読み直せ」と言う)。
    /// **常に空を返す** —— 目録から外すと鍵の集合が変わるので、まず黙らせて次のラウンドで消す
    static func browserA11yFallbackNote(_ snapshot: SnapshotResponse) -> String { "" }

    /// **WebView の中身を1つも読めなかった木**(申告 `webViewPath == dom-unread`。iOS in-app と
    /// Android の自作アプリ経路の両方が出す)。理由は申告した本人の `note` を引く —— 推測しない。
    /// 木が画面を代表していない事実なので、webViewGapNote と同じ棚(上流)に置く(F25)
    static func webViewUnreadNote(_ snapshot: SnapshotResponse) -> String {
        guard snapshot.webViewPath == WebViewPath.domUnread else { return "" }
        let why = (snapshot.note ?? "").isEmpty ? "" : " Why: \(snapshot.note!)."
        return "note: the WebView contents could not be read, so this tree holds only native elements"
            + " — a web element that is on screen cannot be found in it, and its absence here proves"
            + " nothing.\(why) Verify with ft_screenshot.\n"
    }

    /// 旧実装(既定が DOM だった頃)。**復活させるなら根拠を台帳へ**
    static func browserA11yFallbackNoteLegacy(_ snapshot: SnapshotResponse) -> String {
        guard let id = snapshot.sessionBundleID, WebViewDOM.knownBrowserIDs.contains(id) else { return "" }
        guard !snapshot.elements.contains(where: { $0.web == true }) else { return "" }
        // ブラウザ chrome しか無い画面は別の注記の担当(こちらまで出すと二重に言う)
        guard snapshot.elements.contains(where: { ($0.identifier ?? "").isEmpty }) else { return "" }
        // **`note: ` は各注記が自分で付ける規約**(目録側は付けない。付け忘れて
        // この注記だけ書式が揃っていなかった)。末尾の改行も同様
        return "note: the page content below came from the accessibility tree, not the DOM"
            + " — the browser publishes only part of a page there, so text that IS on screen can be missing."
            + " Re-read with ft_snapshot, or check with ft_screenshot before concluding it is absent.\n"
    }

    /// **アドレス欄はあるのに webView 要素そのものが1つも無い**形の注記
    /// (jma.go.jp を Android Chrome で実測)。
    ///
    /// なぜ要るか: `webViewGapNote` は webView 容器の**内側**しか測れず、`emptyTreeNote` は
    /// `elements.isEmpty` の完全一致でしか発火しない。Chrome が自分の chrome(ツールバー・
    /// アドレス欄)しか公開せず、ページ本体を一切木に出さない画面は、この2本のどちらの網にも
    /// 掛からずに黙って通り抜ける —— 実測(and-browser_jma_notree)は要素19件が全部ブラウザ
    /// chrome で、画面の 88.6% が空白のまま報告されていた。
    ///
    /// **判定は `FTCore.TreeCoverage.missingPageContent` が唯一の定義元**(閾値・ブラウザに
    /// 絞る理由・witness の実測はそちら)。ここが持つのは文言だけ
    ///
    /// **ネイティブのモーダルにも同じ鍵で答える**: 木がモーダルの部分木だけに
    /// なる形はブラウザ固有ではない —— 固定コーパスの `and-dialog_confirm`(設定の確認
    /// ダイアログ。木は6要素で背後の設定画面は消えている)と `and-overflow`(地図のメニュー)が
    /// 同じ形。**注記の鍵は増やさない**(`NoteBudgetTests` が本数と鍵の集合を等号で固定して
    /// おり、増やすには台帳と手数の計測が要る)ので、判定で分岐して文言だけ切り替える
    static func missingPageContentNote(_ snapshot: SnapshotResponse) -> String {
        if !TreeCoverage.missingPageContent(in: snapshot) {
            guard TreeCoverage.collapsedTree(in: snapshot) else { return "" }
            // **判定に使った量をそのまま印字する**(collapsedTree は端の空白で判定する)。
            // 内側込みの素の未代表率を出すと、読み手が確かめようのない数字になる
            let percent = Int(
                (TreeCoverage.edgeUnrepresentedFractionExcludingKeyboard(snapshot) * 100).rounded())
            return "note: \(percent)% of the screen has no element in the tree at all — a modal,"
                + " sheet or menu may have replaced it, in which case everything behind it is gone"
                + " from the tree (it cannot be waited for, scrolled to, or tapped by selector, and"
                + " an assertion that something is absent would pass for the wrong reason)."
                + " Check with ft_screenshot.\n"
        }
        // **次の一手まで書く**(原因が判った)。Chromium は a11y を要求する
        // サービスが繋がってから木を作り、**出来上がるまで数秒かかる**。その窓で撮ると
        // chrome だけが返る(実測: ブリッジ起動直後 19 要素 → 5 秒後 135 要素で安定)。
        // 恒久的な故障ではないので、**まず読み直させる**(screenshot だけを勧めると
        // 「このページは読めない」と結論させてしまう)
        return "note: the browser published no page content to the accessibility tree at all —"
            + " not even a webView container, only its own chrome (address bar, toolbar, tabs)."
            + " If the bridge was just started, the tree can be empty for a few seconds while the"
            + " browser builds it — read again with ft_snapshot before concluding anything."
            + " Elements missing from the tree cannot be waited for, scrolled to, or tapped by"
            + " selector; ft_screenshot shows what is actually on screen.\n"
    }

    /// センターX が近い(=セルが中央揃えで縦に並ぶ)ことを列とみなす許容誤差。**容器幅の比率**
    /// (iOS=pt/Android=px の桁違いを吸収する)。実測(tenki.jp 2週間天気)では
    /// 同じ日付列内の要素(天気アイコン・気温・降水確率)の centerX 差は 2px 未満だった
    static let gridColumnCenterToleranceRatio = 0.02
    /// 同じ行とみなす y 区間の重なり(Jaccard = 交差 / 和集合)。幅ベースの overlap/min(width) は
    /// 不採用(実測): ナビの全幅リンクのような大きな要素に、無関係な小要素が
    /// 「収まっている」というだけで同じ列に巻き込まれた(実際に3件の誤検知を作った)
    static let gridRowOverlapRatio = 0.6
    static let gridMinColumns = 3
    static let gridMinRows = 2
    /// **見出し行が入る余地**の下限。格子の直上の空白が「行の間隔(pitch)の何倍あれば
    /// 1行ぶん抜けたと言えるか」。
    ///
    /// なぜ要るか(Yahoo!天気を iOS Safari で実測。**実アプリでの初めての誤検知**):
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
    /// なぜ要るか(Android の Chrome で実測): tenki.jp の2週間天気で、
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
    ///: 幅の重なり(overlap/min-width)や全画面での列クラスタリングは、無関係な
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
    /// なぜ要るか(J1順位表を iOS Safari(Simulator)/ Android Chrome(Emulator)で実測):
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

    /// アドレス欄の identifier 既知集合(実測)。Android Chrome = `url_bar` /
    /// iOS Safari = `TabBarItemTitle`(通常時)・`URL`(アドレス欄をタップした状態)。
    ///
    /// **「値が URL らしい textField」というフォールバックは置かない**(実装して撤回)。
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
    /// なぜ要るか(実測): `ft_open_url` に同じ URL を渡しても、iOS Safari はフル版、
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
    /// なぜ要るか(Android の Chrome で実測): アクセシブルな名前を持たないリンクに
    /// Chrome は URL を入れる。実物は `"13101"`(市区町村リンク=画面には「千代田区」と描画)・
    /// `"dc2557a17fdf039c74261b0b5da109ec"`・`"details%3Fid%3Dcom…"`(400字超)。
    /// **黙っていると読み手はこれを画面の文字だと読む** —— 同じ画面を iOS Safari で読むと
    /// ちゃんと「千代田区」なので、OS 差が「アプリの差」に見える。
    ///
    /// **数字だけの形は判定に入れない**(`13101`): 本文の数値(気温・件数)と区別が付かず、
    /// 誤検知のほうが害になる。ここで名指しできるのは「人が書いた文には出ない綴り」だけ
    ///
    /// **webView の中だけを見る**(E2EAppCMP のライフサイクル画面が witness):
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
    /// `abbreviated`(F-6 の対象拡大): 明細(`listed`)は既定と同じまま、
    /// 冒頭の長い advice だけ「初出の注記を見よ」に圧縮する。呼び手は once 経由(instance の
    /// `unlabeledClickablesNote(_:)` ラッパ)で使い分ける
    static func unlabeledClickablesNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false,
                                        cache: SnapshotAnnotationCache? = nil) -> String {
        // **候補を先に絞ってから grade する**(レビュー指摘)。木の全要素を
        // 無条件に grade すると、**注記が1バイトも出ない画面で最も高くつく** ——
        // 実測(debug・固定コーパス)で 233 要素の画面が 3497ms、120 要素で 1208ms。
        // ft_snapshot 全体が 203 要素で 1.2 秒なので、桁で効いてしまう。
        // grade するのは**候補と同じ矩形の要素だけ**にする
        let candidates = snapshot.elements.filter {
            $0.type == "clickable" && ($0.identifier ?? "").isEmpty && ($0.label ?? "").isEmpty
        }
        guard !candidates.isEmpty else { return "" }
        // **filter の外で1回だけ求める**(レビュー指摘): クロージャの中で呼ぶと
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
            // **「セレクタを書けない」は嘘だった**: id を持つ祖先があれば
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

    /// **同じ矩形に、書けるセレクタを持つ要素が居るか**(設定アプリの監査)。
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
    /// **`.stable` の要素だけを数える**(自分で踏んだ): `selector(for:)` は索引付きの
    /// スコープ記法も返すので、素で使うと**無ラベル clickable 自身が「書ける」に該当し、
    /// 自分自身を twin として黙る**(コーパスで ios-home / ios-maps_route_options の
    /// 真陽性まで消えた)。注記の趣旨は「索引記法より良い、位置に依存しない書き方がある」
    /// なので、`.indexed` は代替として数えない
    /// **`cache` を必ず通す**(レビュー指摘): 自前で `SelectorNaming` を作ると、
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
}
