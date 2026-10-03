// Android システムイメージの導入本体。`fleetest api install-system-image`(ApiInstallSystemImageCommand)と
// `fleetest profile setup --auto-device --accept-licenses`(ProfileSetupCommand)が共有する。
// **ライセンスはここでは判断しない** —— 呼び手が本人の承諾を確認してから呼ぶ契約(呼び出し側の
// --accept-licenses)。`sdkmanager --licenses` は SDK 全体を一括承諾するため使わない。
// 進捗は log クロージャで受ける(NDJSON か通常出力かは呼び手の責務)。

import Foundation
import FTAndroid
import FTCore

enum SystemImageInstaller {

    /// api install-system-image の finished.error にそのまま載る(LocalizedError)
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// --install 中に出る「ライセンスに同意しますか? [y/N]」への回答回数の上限。
    /// システムイメージ本体は通常1問だが、未導入の依存(platform-tools 等)を伴って増えることがある。
    /// 実測ではなく安全側の余裕値 —— 尽きても残りのプロンプトは未回答のまま stdin が閉じるだけで、
    /// sdkmanager 側が「承諾されなかった」として失敗する(待ち続けはしない)
    static let licenseAnswerRepeatCount = 20

    /// 検証済み package("system-images;android-<N>;<tag>;<abi>")を3分割する。
    /// validatePackage を通っている前提(通っていなければ nil)
    static func components(of package: String) -> (apiLevel: String, tag: String, abi: String)? {
        let segments = package.components(separatedBy: ";")
        guard segments.count == 4, segments[1].hasPrefix("android-") else { return nil }
        return (String(segments[1].dropFirst("android-".count)), segments[2], segments[3])
    }

    static func install(package: String, log: (String) -> Void) throws {
        guard let parts = components(of: package) else {
            throw Failure("invalid --package: \(package)")
        }
        guard let sdkRoot = AndroidSDKLocator.findSDKRoot() else {
            throw Failure("Android SDK not found (check ANDROID_HOME / ANDROID_SDK_ROOT)")
        }
        let targetDir = sdkRoot.appendingPathComponent(
            "system-images/android-\(parts.apiLevel)/\(parts.tag)/\(parts.abi)")
        if FileManager.default.fileExists(atPath: targetDir.path) {
            log("Already installed: \(package)")
            return
        }

        guard let sdkmanagerURL = AndroidSDKLocator.findSDKManager() else {
            throw Failure(
                AndroidSDKLocator.sdkManagerMissingMessage + ". " + AndroidSDKLocator.avdManagerInstallHint)
        }

        log("Downloading and installing \(package) (this can take several minutes)...")
        let java = AndroidSDKLocator.javaForSDKTools()
        // sdkmanager --licenses は SDK 全体を一括承諾するため使わない。--install が対話で出す
        // 「Accept? (y/N)」だけに答える(件数はライセンスの数だけ)。No timeout: ダウンロード時間は
        // ネットワーク依存で上限の根拠が無い
        let result = try Shell.run(
            AndroidSDKLocator.sdkToolCommand(sdkmanagerURL, ["--install", package], java: java),
            timeout: nil,
            stdin: Data(String(repeating: "y\n", count: licenseAnswerRepeatCount).utf8))

        guard result.status == 0, FileManager.default.fileExists(atPath: targetDir.path) else {
            var message = "sdkmanager --install failed: \(result.tail)"
            if java == .missing { message += " (\(AndroidSDKLocator.javaMissingHint))" }
            throw Failure(message)
        }
        log("Installed: \(package)")
    }
}
