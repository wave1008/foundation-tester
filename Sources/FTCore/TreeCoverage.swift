// 「木が画面を代表していない」ことの判定。**MCP と DSL の唯一の定義元**。
//
// 打ち切り(`truncatedCount`)はブリッジが件数を申告するので事実として扱えるが、こちらは
// **申告が無いまま木が画面の一部を落としている**形で、幾何からしか疑えない。原因は2つ:
//   1. ブラウザがページの a11y を部分的にしか公開しない(Android の Chrome。webView 容器は
//      居るのに、その内側に何も無い帯が残る)
//   2. ブラウザが自分の chrome しか公開せず、webView 容器すら出さない(木の構築が終わる前に
//      撮った窓。実測でブリッジ起動直後 19 要素 → 5 秒後 135 要素)
//
// **失敗の型は打ち切りと同じ**(不完全な木から「無い」を結論する = 否定アサーションの
// 誤った成功)。打ち切り側だけ `retakenAtElementLimitCeiling` で塞いであり、こちらは
// MCP の注記にしか無かった(2026-08-15 に降ろした)。
//
// **判定だけをここに置き、文言は呼び手ごとに持つ**(docs/design.md の規律)。
// MCP はツール名で逃げ道を書き(ft_screenshot / ft_snapshot)、DSL は StepNote で運ぶ。
//
// **断定はしない**(新しい検知は警告から始める)。DSL 側はこの判定で run を赤にせず注記に留める
// —— 空のページに対する `notExist` は正当な書き方で、区別する材料が木に無い。

import Foundation

public enum TreeCoverage {

    // MARK: - webView 容器の内側の空白帯

    /// 帯を「異常」と数える下限。**容器比と画面比の両方**を要求する(小さな容器の中の
    /// 小さな穴で騒がないため)。単位は比率(0〜1)。
    ///
    /// 根拠(2026-08-12・固定コーパスの webView を持つ4画面): 取りこぼしのある Chrome の1枚が
    /// **実測 302px(容器の 13.6%)**、取りこぼしの無い iOS Safari の3枚が **0/14/29px(0〜3.3%)**。
    /// 8% はその間に置いた。**尽きたとき**(実アプリで誤検知が出る)は閾値を動かす前に
    /// `Tests/Fixtures/RealAppSnapshots/` へその画面を足し、SweepHarnessTests で件数を見る
    public static let gapBandContainerFraction = 0.08
    public static let gapBandScreenFraction = 0.05

    /// 空白帯の走査に使う分割数。**位置の候補を決めるだけ**で高さの量子化には使わない
    /// (`emptyBands` の doc)。木のサイズに比例した O(n) で応答ごとに払える
    public static let gapScanSlices = 60

    /// 空白帯が見つかった webView 容器1つぶん
    public struct Gap: Sendable {
        public let container: ElementInfo
        /// 閾値を超えた帯を y の昇順で**全部**(名指しの本数を絞るのは呼び手の仕事)
        public let bands: [FTRect]
    }

    /// 最初に閾値を超えた webView 容器。**帯は全部返す** ——
    /// 最大の1本だけを返していた頃、実測(2026-08-13・Yahoo!天気の週間画面を Android Chrome で)
    /// で閾値超えが2本あり、黙って落ちた 268px のほうが週間表の日付・気温が丸ごと落ちている
    /// 場所だった。読み手は「警告された1箇所以外は揃っている」と読む
    public static func gap(in snapshot: SnapshotResponse) -> Gap? {
        let screen = snapshot.screen
        guard screen.height > 0 else { return nil }
        for container in snapshot.elements where container.type == "webView" {
            let visible = min(container.frame.y + container.frame.height, screen.y + screen.height)
                - max(container.frame.y, screen.y)
            guard visible > 0 else { continue }
            let bands = emptyBands(inside: container, of: snapshot)
                .filter {
                    $0.height >= visible * gapBandContainerFraction
                        && $0.height >= screen.height * gapBandScreenFraction
                }
            guard !bands.isEmpty else { continue }
            return Gap(container: container, bands: bands)
        }
        return nil
    }

    /// WebView の可視部分のうち、**内側でどの葉とも交わらない連続帯をすべて**(y の昇順)。
    ///
    /// 高さはスライスの量子化を使わず**実要素の縁まで伸ばす**: スライス境界で丸めたままだと、
    /// 帯の両端にあるスライス(境界要素とわずかに交わるだけのスライス)が丸ごと落ちる。
    /// 実測(60分割・容器高2153px→1スライス35.9px)では最大2スライス(≒3.3ポイント)を失い、
    /// 実効閾値が宣言上の8%ではなく最大11.3%になっていた。
    ///
    /// **不変条件**: 選んだスライス列はどのスライスも被覆されていないので、**すべての葉は
    /// 「下端が列の開始 y 以下」か「上端が列の終了 y 以上」のどちらか**を満たす(列に少しでも
    /// 交わる葉があれば、その葉は列内の少なくとも1スライスを被覆し、連続した空き列にならない)。
    /// これにより列の外側にある最も近い葉の縁までは安全に伸ばせる。
    ///
    /// **上端・下端に接する帯は返さない**: 容器の余白はどのページにもあるので、数えると
    /// 健全な木も疑うことになる(実測: iOS Safari の3枚はいずれも先頭の 58px が空)
    public static func emptyBands(inside container: ElementInfo,
                                  of snapshot: SnapshotResponse) -> [FTRect] {
        let screen = snapshot.screen
        let top = max(container.frame.y, screen.y)
        let bottom = min(container.frame.y + container.frame.height, screen.y + screen.height)
        guard bottom - top > 0 else { return [] }
        let sliceHeight = (bottom - top) / Double(gapScanSlices)
        guard sliceHeight > 0 else { return [] }
        // **葉だけを数える**: 容器(webView・scrollView)は帯を丸ごと覆うので、含めると
        // どんな木でも「埋まっている」に見える
        let leaves = snapshot.elements.filter {
            $0.ref != container.ref && $0.scrollable != true && $0.type != "webView"
                && $0.frame.height < (bottom - top)
        }
        var columns: [(start: Int, count: Int)] = []
        var runStart = 0, run = 0
        for slice in 0..<gapScanSlices {
            let y0 = top + Double(slice) * sliceHeight
            let covered = leaves.contains {
                $0.frame.y < (y0 + sliceHeight) && ($0.frame.y + $0.frame.height) > y0
            }
            if covered {
                // 内側で閉じた帯だけを候補にする(runStart > 0 = 上端に接していない)
                if run > 0, runStart > 0 { columns.append((runStart, run)) }
                run = 0
            } else {
                if run == 0 { runStart = slice }
                run += 1
            }
        }
        // 末尾で終わった帯(下端に接する)は候補にしない = ここでは拾わない
        return columns.map { column in
            let columnStart = top + Double(column.start) * sliceHeight
            let columnEnd = top + Double(column.start + column.count) * sliceHeight
            let trueTop = leaves.filter { $0.frame.y + $0.frame.height <= columnStart }
                .map { $0.frame.y + $0.frame.height }.max() ?? columnStart
            let trueBottom = leaves.filter { $0.frame.y >= columnEnd }
                .map(\.frame.y).min() ?? columnEnd
            return FTRect(x: container.frame.x, y: trueTop,
                          width: container.frame.width, height: trueBottom - trueTop)
        }
    }

    // MARK: - webView 容器そのものが無い形

    /// **画面全体**のうち、どの要素の frame とも縦に交わらない最大の帯の割合(0〜1)。
    /// `emptyBands(inside:of:)` の画面全体版 —— あちらは webView 容器の**内側**しか測れないので、
    /// webView 要素が1つも無い画面には使えない。
    ///
    /// 判定は縦だけ: 各要素の frame を画面の上下端で切り、縦の重なりが無い要素は無視する
    /// (横方向は見ない = emptyBands と違って容器の x 範囲を持たないため)。
    /// 残った区間を昇順に流し、隙間の最大値を返す。screen.height <= 0 では測れないので 0
    public static func unrepresentedScreenFraction(_ snapshot: SnapshotResponse) -> Double {
        let screen = snapshot.screen
        guard screen.height > 0 else { return 0 }
        let top = screen.y, bottom = screen.y + screen.height
        let intervals = snapshot.elements.compactMap { element -> (Double, Double)? in
            let y0 = max(element.frame.y, top)
            let y1 = min(element.frame.y + element.frame.height, bottom)
            return y1 > y0 ? (y0, y1) : nil
        }.sorted { $0.0 < $1.0 }
        var cursor = top
        var largest = 0.0
        for (y0, y1) in intervals {
            if y0 > cursor { largest = max(largest, y0 - cursor) }
            cursor = max(cursor, y1)
        }
        if bottom > cursor { largest = max(largest, bottom - cursor) }
        return largest / screen.height
    }

    /// ページ本体が1つも公開されていないと疑う空白の割合。根拠(2026-08-13 の固定コーパス):
    /// 実際に本体が落ちていた `and-browser_jma_notree` が **0.886**、アドレス欄はあるが健全な
    /// `and-browser_urlmenu` が 0.059。0.5 はその間で、**アドレス欄の存在と併せてのみ**使う
    public static let missingPageContentFractionThreshold = 0.5

    /// アドレス欄になり得る identifier。**リテラルはここ1箇所にしか置かない**
    public static let addressBarIdentifiers: Set<String> = ["url_bar", "TabBarItemTitle", "URL"]

    /// アドレス欄になり得る要素の生の探索(**webView の有無を問わない**)。
    /// 2つの呼び手が逆の前提で使う: MCP の `addressBarNote` は webView が居るときだけ通す /
    /// `missingPageContent` は逆に webView が**居ない**ことを条件にする
    public static func addressBarCandidate(in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.first {
            addressBarIdentifiers.contains($0.identifier ?? "") && !($0.value ?? "").isEmpty
        }
    }

    /// **アドレス欄はあるのに webView 要素そのものが1つも無い**形。
    ///
    /// **ブラウザにだけ絞る**(アドレス欄の存在が要る理由): 空白の割合だけで判定すると
    /// ネイティブ画面まで拾う —— 地図の `and-overflow` は空白率 0.564 まで達するが、
    /// アドレス欄が無い = ブラウザではないので黙るべき
    public static func missingPageContent(in snapshot: SnapshotResponse) -> Bool {
        !snapshot.elements.contains { $0.type == "webView" }
            && addressBarCandidate(in: snapshot) != nil
            && unrepresentedScreenFraction(snapshot) >= missingPageContentFractionThreshold
    }

    // MARK: - まとめ(否定判定の裏取り)

    /// この木は画面を代表していない疑いがあるか。**否定アサーションが「無い」を結論する前**に
    /// 呼ぶ(`StepExecutor` の notExists / count)。**真なら失敗にするのではなく注記する** ——
    /// 幾何からの疑いであって申告された事実ではないので、断定すると空のページに対する
    /// 正当な `notExist` が書けなくなる
    public static func underreports(_ snapshot: SnapshotResponse) -> Bool {
        gap(in: snapshot) != nil || missingPageContent(in: snapshot)
    }
}
