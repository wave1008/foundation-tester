// `warm-ocr`(Vision の認識器のコンパイルキャッシュを同じプロセス名でコミットさせる暖機)を
// **機械で同時に 1 本**に抑える。複数の機械に跨る profile では親が別プロセスになり、run の
// 経路を通るたびに 1 本ずつ起きて 3 本が同じキャッシュを競ってコンパイルしていた(実測 2026-09-10)。
// 鍵はプロセス名(= キャッシュの鍵と同じ)。flock は所有プロセスが死ねば自動で外れるので、
// 途中で殺されても次の暖機を永久に塞がない。

import Foundation

public enum OCRWarmupLock {
    /// **待つ版**: 別の暖機(warm-ocr)がコンパイル中ならその完了まで待ってから取る。
    /// シナリオ実行プロセスの探りが使う —— 待たずに自分でもコンパイルすると、8 レーンぶんの
    /// プロセスが同じモデルを同時にコンパイルして CPU を奪い合い、しかも自分の分はコミットされない。
    /// 待てば warm-ocr のコミット直後に 0.2 秒で読める。**協調スレッドプールの上で呼ばない**
    /// (ブロックする。呼び手は専用の Thread)
    public static func acquire(processName: String,
                               directory: URL = FileManager.default.homeDirectoryForCurrentUser
                                   .appendingPathComponent(".fleetest", isDirectory: true)) -> FileHandle? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ocr-warmup-\(processName).lock")
        let fd = open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX) == 0 else { close(fd); return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// 取れたら開いたままの FileHandle(閉じるまで保持)。取れなければ nil = 別の暖機が走っている
    public static func tryAcquire(processName: String,
                                  directory: URL = FileManager.default.homeDirectoryForCurrentUser
                                      .appendingPathComponent(".fleetest", isDirectory: true)) -> FileHandle? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ocr-warmup-\(processName).lock")
        // **`FileManager.createFile` を使わない** —— 既存のパスに書くと別の inode に置き換わり、
        // 先客の flock(旧 inode に付いている)と衝突しなくなる(2026-09-10 にテストで踏んだ)。
        // O_CREAT は既存ファイルをそのまま開く
        let fd = open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
