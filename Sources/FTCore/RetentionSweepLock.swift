// 保持容量の掃除(`fleetest clean`)を**機械で同時に1本**に抑える錠。
//
// 掃除の対象はシミュレータの添付(機械グローバル)を含むので、鍵も機械グローバル
// (`~/.fleetest/retention-sweep.lock`)。**flock は所有プロセスが死ねば自動で外れる**ので、
// 途中で殺された掃除が次の掃除を永久に塞がない(pid と mtime の台帳にしない理由)。
// **取るのは消す処理だけ**(背景の自動掃除・`fleetest clean`・`api clean`)。dry-run と使用量の
// 読み(`api retention --usage`)は1バイトも消さないので取らない。

import Foundation

public enum RetentionSweepLock {

    public static let fileName = "retention-sweep.lock"

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fleetest", isDirectory: true)
    }

    /// 取れたら開いたままの FileHandle(**閉じるまで保持**。解放はプロセスの終了でもよい)。
    /// 取れなければ nil = 別の掃除が走っている。**待たない**(背景の掃除は先客に任せて抜け、
    /// 手動の掃除は利用者に知らせて抜ける)。取れたら自分の pid を書く(先客の名指し用。判定には使わない)
    public static func tryAcquire(directory: URL = defaultDirectory) -> FileHandle? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        // **`FileManager.createFile` を使わない** —— 既存のパスに書くと別の inode に置き換わり、
        // 先客の flock(旧 inode に付いている)と衝突しなくなる(OCRWarmupLock と同じ罠)。
        // pid も同じ fd へ ftruncate + write で書く(inode を変えない)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        let pid = Array("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// 先客の pid(表示用)。**錠が取れなかった直後に読む**。読めなければ nil
    public static func holderPID(directory: URL = defaultDirectory) -> pid_t? {
        let url = directory.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
