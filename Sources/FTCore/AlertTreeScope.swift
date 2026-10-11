// アラートが前面にある間の木の範囲。**MCP(snapshotBody)と DSL(失敗レポートの要素一覧)が共有する**(ユーザー決定:
// アラートの間の背面の木は押せない要素の一覧で、読み手はそこから次の手や原因を探してしまう)。
// システムアラート(SpringBoard)は木に載らないので呼び手が照会で知り、木を丸ごと伏せる。
// アプリ内のアラート(木の中の alert)はここで見つけ、その部分木だけを残す。

import Foundation

public enum AlertTreeScope {

    /// アプリの木の中の alert。いちばん手前 = 木の順で最後の1つ。**画面に描かれているものだけ**(枠が0・画面の外の
    /// alert は閉じた後の残りかもしれない。それで木を伏せると、読み手には押しても何も起きないアラートだけの画面が見え続ける)
    public static func frontInAppAlert(in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.last {
            ElementInfo.normalizedType($0.type) == "alert" && $0.frame.width > 0 && $0.frame.height > 0
                && ScrollGeometry.intersection($0.frame, snapshot.screen) != nil
        }
    }

    /// アラートとその子孫だけの木(ref・枠はそのまま = 一覧の ref でそのまま押せる)
    public static func alertOnly(_ alert: ElementInfo, in snapshot: SnapshotResponse) -> SnapshotResponse {
        var only = snapshot
        only.elements = [alert] + LocatorResolver.descendants(of: alert, in: snapshot.elements)
        return only
    }

    /// アラートの中の押せる要素のラベル(注記に並べる)
    public static func buttonLabels(of alert: ElementInfo, in snapshot: SnapshotResponse) -> [String] {
        LocatorResolver.descendants(of: alert, in: snapshot.elements)
            .filter { BridgeSnapshotThinning.operableTypes.contains($0.type) }
            .compactMap { $0.label.map(SnapshotRenderer.displayText) }.filter { !$0.isEmpty }
    }
}
