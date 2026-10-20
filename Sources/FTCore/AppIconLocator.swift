// AppIconLocator.swift
// tapAppIcon(Shirates 準拠)専用の純粋ロジック。ホーム画面/ドロワー/ページ送り探索の
// 「一致判定」「変化検知」「打ち切り判定」だけを切り出す(実機なしで単体テストできる部分)。
// ドライバ呼び出し(home/snapshot/drag/tap)は FTDSL/CommandsAppControl.swift の tapAppIcon 実装が持つ。

/// アイコン探索の純粋ロジック。
public enum AppIconLocator {
    /// スナップショットから appIconName に一致する要素を探す(label 完全一致。Shirates も完全一致)。
    /// 複数一致時は snapshot の並び順で最初の1件
    public static func findIcon(_ name: String, in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.first { $0.label == name }
    }

    public static func centre(of icon: ElementInfo) -> (x: Double, y: Double) {
        (icon.frame.x + icon.frame.width / 2, icon.frame.y + icon.frame.height / 2)
    }

    /// アイコンの中心がその木の画面の中にあるか。**SpringBoard の木が表示中の画面と違う場面の枠を載せることがある**
    /// (iPhone Duo の Simulator・Xcode 27.2 RC: 内側の画面の場面の枠が外側の画面の木に混ざり、中心が y < 0 になる。
    /// docs/open-issues.md)。撃っても画面の外へ空振りするだけなので、呼び手は読み直して、直らなければ撃たずに失敗する。
    /// 判定は `TapTargetGeometry.isPointOnScreen`(MCP・ライブ操作の画面内判定と同じ。画面が分からなければ true)
    public static func isCentreOnScreen(_ icon: ElementInfo, in snapshot: SnapshotResponse) -> Bool {
        let point = centre(of: icon)
        return TapTargetGeometry.isPointOnScreen(x: point.x, y: point.y, screen: snapshot.screen)
    }

    /// ホーム画面の木の画面が、表示中の画面の大きさ(pt)と合っているか。**内蔵画面が2枚の機種で、木が表示していない側の画面の
    /// 寸法で来ることがある**(iPhone Duo の Simulator・Xcode 27.2 RC: 外側 466x678 を表示中に木は 951x669 = 内側の横向き。
    /// その木にはアイコンが載らない・載っても外側の画面に当たらない)。向きは問わない(横向きのアプリでも SpringBoard の木は
    /// 縦のまま = 幅と高さの入れ替わりは一致とみなす)。1pt 未満の差は丸め
    public static func treeMatchesShownDisplay(screen: FTRect, shownWidth: Double, shownHeight: Double) -> Bool {
        guard screen.width > 0, screen.height > 0, shownWidth > 0, shownHeight > 0 else { return true }
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1 }
        return (same(screen.width, shownWidth) && same(screen.height, shownHeight))
            || (same(screen.width, shownHeight) && same(screen.height, shownWidth))
    }

    /// ドロワー/ページ送り探索で「画面が変わったか」を見るための署名。ラベル集合が同じなら
    /// 同じ画面とみなす(要素の並び順・ref 番号のブレを無視するため sort してから連結)
    public static func signature(of snapshot: SnapshotResponse) -> String {
        snapshot.elements.compactMap { $0.label }.sorted().joined(separator: "\u{1}")
    }

    /// ドロワー/ページ送りの打ち切り判定: 2回連続で画面が変わらなければ端に着いたとみなす
    /// (StepExecutor の scrollTo と同じ規律)。上限回数に達したときも打ち切る
    public static func shouldStopSearch(consecutiveUnchanged: Int, attempts: Int, maxAttempts: Int) -> Bool {
        consecutiveUnchanged >= 2 || attempts >= maxAttempts
    }
}
