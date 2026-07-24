// emulator stdout/stderr ログの所在(パス契約はここが唯一の正)。
// 書き込み: DeviceBooter.startEmulator(ブート毎 truncate=emulator プロセス起動時のみ。
// guest reboot では truncate されない)/ 読み取り: AndroidHealthProbe(Metal エラー計数)

import Foundation

enum EmulatorLog {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ftester/emulator")
    }

    static func url(avdID: String) -> URL {
        directory.appendingPathComponent(avdID.replacingOccurrences(of: "/", with: "_") + ".log")
    }
}
