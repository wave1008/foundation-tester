// UnicodeIME.swift
// adb `input text` は ASCII しか入力できないため、日本語などの非 ASCII 文字は
// Unicode 対応 IME(ADBKeyBoard, GPL-2.0, https://github.com/senzhk/ADBKeyBoard)を
// デバイスに入れて `am broadcast -a ADB_INPUT_B64` で送る(Appium と同じ方式)。
// - APK はリポジトリに同梱せず、初回利用時に ~/.ftester/ へダウンロードして自動インストール
// - 切り替え前の IME を保存し、terminate() で復元する

import Foundation
import FTCore

extension AndroidDriver {

    public static let unicodeIMEPackage = "com.android.adbkeyboard"
    public static let unicodeIMEID = "com.android.adbkeyboard/.AdbIME"
    static let unicodeIMEAPKURL = "https://github.com/senzhk/ADBKeyBoard/raw/master/ADBKeyboard.apk"

    /// 複数ワーカーが同時に初回ダウンロードしたときの競合防止(同一プロセス内)
    static let apkFetchLock = NSLock()

    // MARK: - 入力

    /// 非 ASCII テキストを Unicode IME 経由で入力する。
    /// 事前条件: 入力先フィールドにフォーカスがあること(type(ref:) がタップ済み)
    func typeViaUnicodeIME(_ text: String) async throws {
        try await ensureUnicodeIME()
        let b64 = Data(text.utf8).base64EncodedString()
        let result = try adb(["shell", "am", "broadcast",
                              "-a", "ADB_INPUT_B64", "--es", "msg", b64])
        guard result.output.contains("Broadcast completed") else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "Unicode IME への送信に失敗しました: \(result.tail)")
        }
        // IME 側の commitText 反映を待つ
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - IME 切り替え

    func currentIME() throws -> String {
        try adb(["shell", "settings", "get", "secure", "default_input_method"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unicode IME を(必要ならインストールして)アクティブにする。
    /// 切り替え前の IME は persistState 経由で保存され terminate() で復元される
    func ensureUnicodeIME() async throws {
        let current = try currentIME()
        if current == Self.unicodeIMEID { return }

        let packages = try adb(["shell", "pm", "list", "packages", Self.unicodeIMEPackage])
        if !packages.output.contains("package:\(Self.unicodeIMEPackage)") {
            let apk = try Self.locateOrFetchAPK()
            var install = try adb(["install", "-r", apk.path])
            if install.output.contains("DEPRECATED_SDK_VERSION") {
                // Android 14+ は古い targetSdk のインストールを既定でブロックする
                install = try adb(["install", "-r", "--bypass-low-target-sdk-block", apk.path])
            }
            guard install.output.contains("Success") else {
                throw DriverError.badResponse(status: Int(install.status),
                    body: "ADBKeyboard のインストールに失敗しました: \(install.tail)")
            }
        }

        // ハードウェアキーボード有効なデバイス(エミュレータ既定)では IME の入力ビューが
        // 作られず ADBKeyboard がレシーバを登録しないことがある → ソフトキーボード表示を強制
        let showIme = try adb(["shell", "settings", "get", "secure", "show_ime_with_hard_keyboard"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        if showIme != "1" {
            if originalShowIMEWithHardKeyboard == nil {
                originalShowIMEWithHardKeyboard = showIme.isEmpty ? "null" : showIme
            }
            _ = try adb(["shell", "settings", "put", "secure", "show_ime_with_hard_keyboard", "1"])
        }

        // "null" や空は保存しない(復元時は ime reset にフォールバック)
        if originalIME == nil, !current.isEmpty, current != "null" {
            originalIME = current
        }
        persistState()

        _ = try adb(["shell", "ime", "enable", Self.unicodeIMEID])
        _ = try adb(["shell", "ime", "set", Self.unicodeIMEID])
        guard try await waitForUnicodeIMEReady() else {
            throw DriverError.badResponse(status: 1, body:
                "Unicode IME に切り替えられません(\(Self.unicodeIMEID) のレシーバが登録されない)。"
                + "入力先フィールドにフォーカスがあるか確認してください")
        }
    }

    /// IME サービスの起動とブロードキャストレシーバの登録は ime set 後に非同期で行われる。
    /// 受信できる状態になるまで dumpsys でポーリングする(登録済みフィルタは "ADB_INPUT_B64:"
    /// と出る。履歴の "act=ADB_INPUT_B64" とはコロンで区別される)
    private func waitForUnicodeIMEReady() async throws -> Bool {
        for _ in 0..<20 {
            if (try? currentIME()) == Self.unicodeIMEID,
               let dump = try? adb(["shell", "dumpsys", "activity", "broadcasts"]),
               dump.output.contains("ADB_INPUT_B64:") {
                // 登録直後の取りこぼし防止に一拍置く
                try await Task.sleep(nanoseconds: 300_000_000)
                return true
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// 切り替え前の IME・キーボード設定に戻す(未切替なら何もしない)。terminate() から呼ばれる
    func restoreOriginalIMEIfNeeded() {
        if let show = originalShowIMEWithHardKeyboard {
            if show == "null" {
                _ = try? adb(["shell", "settings", "delete", "secure", "show_ime_with_hard_keyboard"])
            } else {
                _ = try? adb(["shell", "settings", "put", "secure", "show_ime_with_hard_keyboard", show])
            }
            originalShowIMEWithHardKeyboard = nil
        }
        guard originalIME != nil || (try? currentIME()) == Self.unicodeIMEID else {
            persistState()
            return
        }
        if let ime = originalIME {
            _ = try? adb(["shell", "ime", "set", ime])
        } else {
            _ = try? adb(["shell", "ime", "reset"])
        }
        _ = try? adb(["shell", "ime", "disable", Self.unicodeIMEID])
        originalIME = nil
        persistState()
    }

    // MARK: - APK の取得

    /// 検索順: FT_ADBKEYBOARD_APK 環境変数 → ~/.ftester/ADBKeyboard.apk → GitHub からダウンロード
    static func locateOrFetchAPK() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["FT_ADBKEYBOARD_APK"],
           FileManager.default.isReadableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }

        apkFetchLock.lock()
        defer { apkFetchLock.unlock() }

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ftester")
        let cached = dir.appendingPathComponent("ADBKeyboard.apk")
        if FileManager.default.isReadableFile(atPath: cached.path) {
            return cached
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("ADBKeyboard.apk.download-\(ProcessInfo.processInfo.processIdentifier)")
        let curl = try Shell.run(["curl", "-fsSL", "--connect-timeout", "15",
                                  "-o", tmp.path, unicodeIMEAPKURL])
        guard curl.status == 0, FileManager.default.isReadableFile(atPath: tmp.path) else {
            try? FileManager.default.removeItem(at: tmp)
            throw DriverError.badResponse(status: Int(curl.status), body: """
                日本語入力用 IME(ADBKeyboard.apk)をダウンロードできません。
                オフライン環境では手動で配置してください:
                  curl -fsSL \(unicodeIMEAPKURL) -o ~/.ftester/ADBKeyboard.apk
                または FT_ADBKEYBOARD_APK=<APKパス> を設定してください。
                \(curl.tail)
                """)
        }
        do {
            try FileManager.default.moveItem(at: tmp, to: cached)
        } catch {
            // 別プロセスが先に配置済みならそれを使う
            try? FileManager.default.removeItem(at: tmp)
            guard FileManager.default.isReadableFile(atPath: cached.path) else { throw error }
        }
        return cached
    }
}
