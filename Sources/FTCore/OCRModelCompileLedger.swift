// OCR の認識器(Vision)をコンパイルしている間の、機械共通の印。コンパイルするプロセス(シナリオ・compile-ocr の子)が
// `~/.fleetest/ocr-compile/<pid>` を置き、host-metrics 常駐プロセスが毎 tick 数える
// (モニターの Vision チャートのコンパイルの帯。UsageLedger と同じ「呼ぶ側が書き、host-metrics が読む」形)。
// 置き場は FT_OCR_COMPILE_DIR で差し替え可(テスト用)。殺されたプロセスの残骸は activeCount が掃除する。

import Foundation
import Synchronization

public enum OCRModelCompileLedger {
    public struct Token: Sendable {
        fileprivate init() {}
    }

    private static let depth = Mutex(0)

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["FT_OCR_COMPILE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest", isDirectory: true)
            .appendingPathComponent("ocr-compile", isDirectory: true)
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

    /// いまコンパイルしているプロセス数(この機械)。生きていない pid のファイルは残骸として消す
    public static func activeCount() -> Int { activeCount(in: directory) }

    /// 数えるのは**置かれてからこれ以上たった印だけ**。コンパイル済み機械でもシナリオの開始時の探りは
    /// 0.2〜0.3 秒かかり、1 秒刻みのサンプルがその一瞬を拾うとチャートにコンパイルの帯がちらつく
    /// (コンパイルしていないのに)。コールドのコンパイルは 20 秒以上なので、1 秒遅れて帯が出ても見落とさない
    static let minimumAge: TimeInterval = 1.0

    /// **`FileManager.createFile` を使わない** —— 一時ファイル(`<pid>.sb-…`)に書いてから付け替える作りで、
    /// シナリオのプロセスでは付け替えが済まずに一時ファイルだけが残り(原因は未特定)、印が立たなかった。
    /// `open(O_CREAT)` は付け替えをしない
    static func markPresent(in dir: URL, pid: Int32) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(String(pid)).path, O_WRONLY | O_CREAT, 0o644)
        if fd >= 0 { close(fd) }
    }

    static func markAbsent(in dir: URL, pid: Int32) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(String(pid)))
    }

    static func activeCount(in dir: URL, now: Date = Date()) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var alive = 0
        for name in names {
            guard let pid = Int32(name) else {
                // pid の名前でないもの(以前の作りが残した `<pid>.sb-…` 等)は、書いた pid がもう居なければ掃除する
                let owner = Int32(name.prefix { $0.isNumber })
                if owner.map({ !ProcessLiveness.isAlive($0) }) ?? true {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                }
                continue
            }
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
