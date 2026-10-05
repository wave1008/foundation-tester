// OCR の認識器(Vision)を暖機している間の、機械共通の印。暖機するプロセス(シナリオ・warm-ocr の子)が
// `~/.fleetest/vision-warmup/<pid>` を置き、host-metrics 常駐プロセスが毎 tick 数える
// (モニターの VN チャートの暖機の帯。UsageLedger と同じ「呼ぶ側が書き、host-metrics が読む」形)。
// 置き場は FT_VISION_WARMUP_DIR で差し替え可(テスト用)。殺されたプロセスの残骸は activeCount が掃除する。

import Foundation
import Synchronization

public enum VisionWarmupLedger {
    public struct Token: Sendable {
        fileprivate init() {}
    }

    private static let depth = Mutex(0)

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["FT_VISION_WARMUP_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest", isDirectory: true)
            .appendingPathComponent("vision-warmup", isDirectory: true)
    }

    /// 同一プロセスで重ねて呼ばれうるので参照カウント。印のファイルは 0→1 で作り 1→0 で消す
    public static func begin() -> Token {
        depth.withLock { count in
            count += 1
            if count == 1 { markPresent(in: directory, pid: ProcessInfo.processInfo.processIdentifier) }
        }
        return Token()
    }

    public static func end(_ token: Token) {
        depth.withLock { count in
            guard count > 0 else { return }
            count -= 1
            if count == 0 { markAbsent(in: directory, pid: ProcessInfo.processInfo.processIdentifier) }
        }
    }

    /// いま暖機しているプロセス数(この機械)。生きていない pid のファイルは残骸として消す
    public static func activeCount() -> Int { activeCount(in: directory) }

    /// 数えるのは**置かれてからこれ以上たった印だけ**。暖まっている機械でもシナリオの開始時の探りは
    /// 0.2〜0.3 秒かかり、1 秒刻みのサンプルがその一瞬を拾うとチャートに暖機の帯がちらつく
    /// (暖機していないのに)。コールドの暖機は 20 秒以上なので、1 秒遅れて帯が出ても見落とさない
    static let minimumAge: TimeInterval = 1.0

    static func markPresent(in dir: URL, pid: Int32) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(String(pid)).path, contents: nil)
    }

    static func markAbsent(in dir: URL, pid: Int32) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(String(pid)))
    }

    static func activeCount(in dir: URL, now: Date = Date()) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var alive = 0
        for name in names {
            guard let pid = Int32(name) else { continue }
            if ProcessLiveness.isAlive(pid) {
                let created = (try? FileManager.default.attributesOfItem(
                    atPath: dir.appendingPathComponent(name).path)[.modificationDate]) as? Date
                if let created, now.timeIntervalSince(created) >= minimumAge { alive += 1 }
            } else {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        return alive
    }
}
