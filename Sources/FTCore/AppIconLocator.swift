// AppIconLocator.swift
// tapAppIcon(Shirates 準拠)専用の純粋ロジック。ホーム画面/ドロワー/ページ送り探索の
// 「一致判定」「変化検知」「打ち切り判定」だけを切り出す(実機なしで単体テストできる部分)。
// ドライバ呼び出し(home/snapshot/drag/tap)は FTDSL/Commands.swift の tapAppIcon 実装が持つ。

/// アイコン探索の純粋ロジック。
public enum AppIconLocator {
    /// スナップショットから appIconName に一致する要素を探す(label 完全一致。Shirates も完全一致)。
    /// 複数一致時は snapshot の並び順で最初の1件
    public static func findIcon(_ name: String, in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.first { $0.label == name }
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
