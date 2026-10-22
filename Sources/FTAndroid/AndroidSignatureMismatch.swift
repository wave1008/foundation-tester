// アプリ本体の `adb install -r` が `INSTALL_FAILED_UPDATE_INCOMPATIBLE`(同じパッケージが別の鍵で署名されて
// 端末に居る)で落ちたときの扱い。入れ直し = アンインストールで**端末上のアプリのデータが消える**ので、
// 消してよいと言える事実が揃ったときだけ入れ直す(ブリッジ APK は使い捨てなので無条件。AndroidBridge.installBridgeIfNeeded)。
//
// - 判定は pm の状態コード名(公開定数)。自由文の一致ではない
// - 事実は2つ: Emulator か(serial の `emulator-` 前置 = 他所と同じ規則)/ 端末に居る側が debuggable か
//   (`WebViewDOMFallback.probeCommand` の dumpsys 出力。別の開発ビルドなら消してよい。ストア版は消さない)
// - **不明は「消さない」へ倒す**(nil を安全側の確定に畳まない)

import Foundation

public enum AndroidSignatureMismatch {
    public static let statusCode = "INSTALL_FAILED_UPDATE_INCOMPATIBLE"

    public enum Action: Equatable {
        /// 理由は入れ直しの通知文に埋める("an Emulator" / "a debuggable build")
        case reinstall(reason: String)
        /// 理由は拒否文言に埋める(`unknown` = 判らなかった)
        case refuse(unknown: Bool)
    }

    public static func action(isEmulator: Bool?, installedDebuggable: Bool?) -> Action {
        if isEmulator == true { return .reinstall(reason: "an Emulator") }
        if installedDebuggable == true { return .reinstall(reason: "a debuggable build") }
        return .refuse(unknown: isEmulator == nil || installedDebuggable == nil)
    }

    public static func isMismatch(installOutput: String) -> Bool {
        installOutput.contains(statusCode)
    }

    /// `dumpsys package <pkg> | grep flags=` の出力(`WebViewDOMFallback.probeCommand` の後半)→ debuggable か。読めなければ nil
    static func installedDebuggable(probeOutput: String, status: Int32) -> Bool? {
        guard status == 0 else { return nil }
        return WebViewDOMFallback.parseProbe(probeOutput).app
    }

    static func refusalMessage(serial: String, package: String?, unknown: Bool) -> String {
        let pkg = package ?? "<package>"
        let why = package == nil
            ? "fleetest could not read the package name from the APK"
            : unknown
            ? "fleetest could not tell whether it is a debuggable build"
            : "it is not a debuggable build (likely a store/release install)"
        return "the device has \(pkg) installed with a different signing key; \(why)."
            + " Android cannot update it in place, and fleetest does not uninstall it automatically"
            + " because that deletes the app's data on this device."
            + " Uninstall it yourself with `adb -s \(serial) uninstall \(pkg)` and run again"
    }

    static func uninstallFailedMessage(serial: String, package: String, tail: String) -> String {
        "the device has \(package) installed with a different signing key, and uninstalling it to install this build"
            + " failed: \(tail). Uninstall it yourself with `adb -s \(serial) uninstall \(package)` and run again"
    }

    /// 前置き(端末名・⚠️)は呼び手が付ける(run はレーン名、DSL は ⚠️、MCP は応答の行)
    static func reinstalledNotice(package: String, reason: String) -> String {
        "\(package) was installed with a different signing key (\(reason)) —"
            + " uninstalled it and installed this build; the app's data on this device was deleted"
    }

}
