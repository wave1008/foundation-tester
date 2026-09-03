// アプリ自身の WebView を DOM(CDP)で読めなかったとき、AndroidDriver.snapshot() は
// **黙って a11y へ落ちて**いた(AndroidWebViewDOM.read が nil を返すだけで理由が消える)。
//
// **実測(2026-09-03、E2E-RN S0010 の DOM 経路検査)**: local(userdebug 系, ro.debuggable=1)は
// 緑、M1Max/M1Ultra(user 系, ro.debuggable=0)は決定的に赤。SUT は3機とも同じ release ビルド
// (アプリの ApplicationInfo.FLAG_DEBUGGABLE も 0)。release ビルドの WebView は、システムか
// アプリの**どちらかが debuggable なときだけ**devtools ソケットを開くので、**両方が
// 非 debuggable な組み合わせだけが構造的に読めない**(直しようが2つ: AVD を userdebug/eng に
// するか、アプリを debuggable ビルドにするか)。それ以外の「ソケットは開くはずなのに読めない」は
// 原因を断定しない。
//
// 形は WebViewShotComposite に揃える: 判定・文言は純粋関数、once ゲートは serial ごと static
// (AndroidDriver のインスタンス変数にしない理由も同じ —— モニターは1枚撮るごとに
// AndroidDriver を作り直すので、インスタンスに閉じた once は毎フレーム鳴る)。

import Foundation

enum WebViewDOMFallback {

    /// なぜ `.appWebView` の DOM 読みが得られなかったか。**観測できた事実**(取れなければ nil)を
    /// 両ケースに持たせる —— `.other` でも「何を確かめて分からなかったか」を言えるようにするため
    enum Reason: Equatable {
        /// システムもアプリも非 debuggable = devtools ソケットは構造的に開かない
        case structurallyClosed(systemDebuggable: Bool, appDebuggable: Bool)
        /// それ以外(ソケットは開くはずなのに読めなかった、または判定できなかった)。断定しない
        case other(systemDebuggable: Bool?, appDebuggable: Bool?)
    }

    /// 観測した2つの事実 → 理由(純粋)。**両方が確実に false のときだけ構造的に閉じていると言う**
    /// (片方でも debuggable ならソケットは開くはずなので、それ以外は「開くはずなのに読めない」)
    static func reason(systemDebuggable: Bool?, appDebuggable: Bool?) -> Reason {
        guard systemDebuggable == false, appDebuggable == false else {
            return .other(systemDebuggable: systemDebuggable, appDebuggable: appDebuggable)
        }
        return .structurallyClosed(systemDebuggable: false, appDebuggable: false)
    }

    // MARK: - 端末への問い合わせ(1往復に畳む。純粋部分と分離)

    /// `ro.debuggable` とアプリの debuggable フラグをまとめて採る区切り
    /// (AndroidWebViewDOM.probeMarker と同じ流儀。別の問い合わせなので別のマーカー)
    static let probeMarker = "--ft-debuggable--"

    /// `ro.debuggable` とアプリの debuggable フラグをまとめて採る adb 引数(純粋)。
    /// **綴りを検めてから素のシェル文字列へ埋める**(AndroidWebViewDOM.probeCommand と同じ規律 ——
    /// `;` を含むパッケージ名が来ると端末上で別コマンドになる)。検めに落ちたら nil
    static func probeCommand(packageID: String) -> [String]? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !packageID.isEmpty, packageID.allSatisfy({ allowed.contains($0) }) else { return nil }
        return ["shell", "getprop ro.debuggable; echo \(probeMarker); "
                + "dumpsys package \(packageID) | grep flags="]
    }

    /// `probeCommand` の出力 → (システム, アプリ) の debuggable(純粋)。
    /// どちらも読み取れなければ nil(不明。呼び出し側は `.other` に読み替える)
    static func parseProbe(_ output: String) -> (system: Bool?, app: Bool?) {
        guard let marker = output.range(of: probeMarker) else { return (nil, nil) }
        let systemPart = output[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let system: Bool?
        switch systemPart {
        case "1": system = true
        case "0": system = false
        default: system = nil
        }
        return (system, appDebuggableFlag(inDumpsysFlags: String(output[marker.upperBound...])))
    }

    /// `flags=0x...`(ApplicationInfo.flags の16進表示)の行から FLAG_DEBUGGABLE(0x2)ビットを読む。
    /// grep は `flags=` を含む行を全部返す(`privateFlags=` 等も混じる)ので、**行頭が
    /// ちょうど `flags=0x` の行だけ**を採る。見つからなければ nil ——
    /// dumpsys package の書式は Android の版でテキスト羅列(`flags=[ HAS_CODE ... ]`)にも化けるため、
    /// 読めない版があること自体は普通で断定しない
    static func appDebuggableFlag(inDumpsysFlags text: String) -> Bool? {
        for line in text.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("flags=0x") else { continue }
            let hex = trimmed.dropFirst("flags=0x".count).prefix(while: { $0.isHexDigit })
            guard !hex.isEmpty, let value = UInt64(hex, radix: 16) else { continue }
            return (value & 0x2) != 0
        }
        return nil
    }

    // MARK: - 文言

    /// 黙って a11y へ落ちたことを知らせる。**何が起きているか・なぜか・何が変わるか・どうすれば
    /// 直るか**の4つを持つ(`.structurallyClosed` のときだけ「なぜ」「どうすれば」まで言える。
    /// `.other` は観測できた事実だけを書き、原因は断定しない)
    static func warning(serial: String, packageID: String, reason: Reason) -> String {
        let head = "⚠️ [\(serial)] could not read \(packageID)'s WebView content over CDP —"
            + " falling back to the accessibility tree. Attributes that only exist in the DOM"
            + " (e.g. placeholder) will not appear on selectors for it. "
        switch reason {
        case .structurallyClosed:
            return head + "The devtools socket is not open here: the system is not debuggable"
                + " (ro.debuggable=0) and the app under test is not a debuggable build either"
                + " (ApplicationInfo.FLAG_DEBUGGABLE unset). Chromium opens that socket when the"
                + " system or the app is debuggable, or when the app itself calls"
                + " WebView.setWebContentsDebuggingEnabled(true) — with neither flag set, the socket"
                + " never opens unless the app makes that call. Fix by running on a userdebug/eng"
                + " system image, with a debuggable build of the app under test, or by calling"
                + " setWebContentsDebuggingEnabled(true) in the app."
                + " Check with: adb -s \(serial) shell getprop ro.debuggable"
        case .other(let systemDebuggable, let appDebuggable):
            return head + "Could not determine why (observed ro.debuggable=\(describe(systemDebuggable)),"
                + " app debuggable flag=\(describe(appDebuggable))). Check with:"
                + " adb -s \(serial) shell cat /proc/net/unix | grep devtools_remote"
        }
    }

    private static func describe(_ value: Bool?) -> String {
        guard let value else { return "unknown" }
        return value ? "1" : "0"
    }

    // MARK: - once ゲート

    /// **プロセス全体で serial ごとに1回だけ**知らせる門。AndroidDriver のインスタンス変数に
    /// してはいけない理由は WebViewShotComposite.shouldWarnBlankCapture と同じ
    static func shouldWarn(serial: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return warnedSerials.insert(serial).inserted
    }
    private static let lock = NSLock()
    private static var warnedSerials = Set<String>()
}
