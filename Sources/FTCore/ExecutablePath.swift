import Foundation

/// 子として起こす実行ファイルのパス。**`.build/debug` は SwiftPM がビルドのたびに消して作り直すリンク**で、その間(実測 約 0.8ms・
/// 最大 7ms。run はシナリオの製品を毎回ビルドする)はリンク経由のパスが解決できず、起動が ENOENT で落ちる。`Bundle.main.executableURL`
/// はリンク経由で起動されたときリンクのパスのまま(実測)なので、子を起こす経路はここを通して実体のパスで指す。
/// `Bundle.main.executableURL` を直に使ってよい箇所(同一性の照合・場所探し・サンドボックスの枠)は `ExecutablePathTests` の許可表
public enum ExecutablePath {
    /// リンクを解決した実体。実体が実行できなければ元のパス(解決できない瞬間・別の配置でも従来どおり動く)
    public static func resolved(_ url: URL) -> URL {
        let real = url.resolvingSymlinksInPath()
        return real != url && FileManager.default.isExecutableFile(atPath: real.path) ? real : url
    }

    /// このプロセス自身の実体。**実体へ解決できた値だけを使い回す**(起こすたびに解決すると、その解決が同じ窓に当たる。
    /// 窓の中で解決するとリンクのパスが返るので、それは控えずに次の回で解決し直す)。実体が後で消えていたら
    /// (ツールチェーンの更新で置き場が変わった等)解決し直す
    public static var current: URL? {
        cache.withLock { cached in
            if let cached, FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
            guard let original = Bundle.main.executableURL else { return nil }
            let real = resolved(original)
            cached = real != original ? real : nil
            return real
        }
    }

    private static let cache = LockedValue<URL?>(nil)
}
