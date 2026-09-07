// 診断用ダンプ(crop の PNG と付随ファイル)の保持期間。**消してよいのは自分が書いたファイルだけ**
// —— 置き場は環境変数で差し替えられるので、拡張子や名前で絞らずに「古いもの」を消すと、
// 同じディレクトリを指された別のダンプや利用者のファイルまで消える(ディレクトリごと消える)。

import Foundation

public enum DumpRetention {
    /// 診断ダンプの保持期間(日)。切り分けは事後に行うので数日分あればよく、
    /// 反転のたびに 1 枚増えるので無期限には置けない
    public static let days = 7.0

    /// `dir` 直下の**通常ファイル**のうち、`prefix` で始まり `extensions` のいずれかで終わり、
    /// かつ `days` より古いものだけを消す。ディレクトリは辿らないし消さない。
    public static func prune(in dir: URL, prefix: String, extensions: Set<String>,
                             now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        else { return }
        let cutoff = now.addingTimeInterval(-days * 24 * 3600)
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), extensions.contains(url.pathExtension) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate, mtime < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
