import Foundation

/// `--junit` の書き出し先を run の**開始前**に見る。
///
/// レポートは run が終わってから書くので、書けないと分かるのは最後だった(フリート run なら
/// 20 分待ってから)。**末尾の書き込み失敗が警告のみで run の成否を変えない規律は変えない**
/// (`Fleetest.swift` の `writeJUnitIfRequested` / `FleetRunner.mergeAndWriteJUnit` /
/// `RemoteRunDispatcher`。失敗 run こそ CI がレポートを要るので、結果を捨てない)——
/// ここは「始める前に分かる分」だけを前倒しする。両者は補完関係で、
/// 途中で埋まったディスク等は従来どおり末尾の警告が拾う。
public enum JUnitOutputPath {

    /// 書けない理由。書けそうなら nil。
    /// **ディレクトリを作らない** —— 検査は引数だけで決まる純粋な判定に留め、実際の作成は
    /// 従来どおり書き出し側が行う(検査が失敗した run の残骸を置かない)。
    public static func unwritableReason(path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "the path is empty" }

        let manager = FileManager.default
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL

        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return "a directory already exists at that path" }
            return manager.isWritableFile(atPath: url.path)
                ? nil : "the file already there is not writable"
        }

        // 実在する最も近い祖先まで遡る(まだ無い中間ディレクトリは書き出し側が作る)
        var ancestor = url.deletingLastPathComponent()
        while true {
            if manager.fileExists(atPath: ancestor.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    return "\(ancestor.path) is a file, so the directory for the report cannot be created"
                }
                return manager.isWritableFile(atPath: ancestor.path)
                    ? nil : "\(ancestor.path) is not writable"
            }
            let parent = ancestor.deletingLastPathComponent()
            // ルートまで遡っても実在しない(標準化済みなので通常ここへは来ない)
            guard parent.path != ancestor.path else { return nil }
            ancestor = parent
        }
    }
}
