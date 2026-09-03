// アプリ自身の WebView を DOM(CDP)で読めなかったとき、AndroidDriver.snapshot() は
// **黙って a11y へ落ちて**いた(AndroidWebViewDOM.read が nil を返すだけで理由が消える)。
//
// **実測(2026-09-03、E2E-RN S0010 の DOM 経路検査)**: local(userdebug 系, ro.debuggable=1)は
// 緑、M1Max/M1Ultra(user 系 = Play Store イメージ, ro.debuggable=0)は決定的に赤。SUT は3機とも
// 同じ release ビルド(ApplicationInfo.FLAG_DEBUGGABLE も 0)。Chromium が devtools ソケットを
// 開くのは、システムかアプリが debuggable か、アプリ自身が setWebContentsDebuggingEnabled(true) を
// 呼ぶときだけなので、**両方が非 debuggable な組み合わせだけが構造的に読めない**。
//
// **読めない理由の大半は正常な過渡**(WebView 未生成・タブ未選択・遷移直後)なので、nil のたびに
// 言うと健全な構成でも鳴る。言うのは**端末の事実から決まる2つだけ**: 構造的に閉じている /
// 同名プロセスが複数でソケットを選べない。**回数は (serial, package) ごとに診断1回**で縛る ——
// 診断が結論を持ったら(過渡でなく事実で決まったら)二度と問い合わせない。
// アプリ未起動・adb 不能は結論ではないので次の miss で引き直す。
//
// 形は WebViewShotComposite に揃える: 判定・文言は純粋関数、メモは static
// (AndroidDriver のインスタンス変数にしない理由も同じ —— モニターは1枚撮るごとに
// AndroidDriver を作り直すので、インスタンスに閉じた once は毎フレーム鳴る)。

import Foundation

enum WebViewDOMFallback {

    /// 言う価値のある理由。**nil = 黙る**(正常な過渡・言えない事実)
    enum Reason: Equatable {
        /// システムもアプリも非 debuggable = devtools ソケットは構造的に開かない
        case structurallyClosed
        /// 同名プロセスが複数でソケットを1つに選べない(推測で選ぶと別プロセスの DOM を木へ差し込む)
        case ambiguousSockets([String])
    }

    /// ソケット解決の結果 + 端末の事実 → 理由(純粋)。
    /// - `.socket`: ソケットはある = 読めなかったのは過渡(タブ未選択等)。黙る
    /// - `.noWebView`: **両方が確実に false のときだけ**構造的に閉じていると言う。片方でも
    ///   debuggable(または不明)なら「WebView がまだ生成されていない」が普通なので黙る
    /// - `.ambiguous`: 事実として言う(直し方が利用者側にある)
    /// - `.appNotRunning` / `.unavailable`: 他の経路が別に落とす。黙る
    static func reason(resolution: AndroidWebViewDOM.AppSocketResolution,
                       systemDebuggable: Bool?, appDebuggable: Bool?) -> Reason? {
        switch resolution {
        case .socket, .appNotRunning, .unavailable:
            return nil
        case .ambiguous(let names):
            return .ambiguousSockets(names)
        case .noWebView:
            guard systemDebuggable == false, appDebuggable == false else { return nil }
            return .structurallyClosed
        }
    }

    /// その解決結果は**端末の事実として結論か**(= メモしてよいか)。アプリ未起動・adb 不能は
    /// 一時的なので結論にしない(次の miss で引き直す)
    static func isConclusive(_ resolution: AndroidWebViewDOM.AppSocketResolution) -> Bool {
        switch resolution {
        case .socket, .noWebView, .ambiguous: return true
        case .appNotRunning, .unavailable: return false
        }
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
    /// 直るか**の4つを持つ。断定するのは端末の事実で決まった理由だけ(`reason` が nil を返す過渡は
    /// そもそもここへ来ない)
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
                + " system image (a Google APIs image, not a Play Store one), with a debuggable build"
                + " of the app under test, or by calling setWebContentsDebuggingEnabled(true) in the app."
                + " Check with: adb -s \(serial) shell getprop ro.debuggable"
        case .ambiguousSockets(let names):
            return head + "Several processes of this package expose a devtools socket"
                + " (\(names.joined(separator: ", "))) and fleetest refuses to guess which one is the"
                + " screen — picking the wrong one would splice another process's DOM into the tree."
                + " Close the extra processes (or restart the app) so only one remains."
        }
    }

    // MARK: - 診断メモ(出力回数の上限)

    /// (serial, package) ごとに**診断は1回**。まだ診断していないときだけ true
    static func needsDiagnosis(serial: String, package: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !diagnosed.contains(Key(serial: serial, package: package))
    }

    /// 結論が出た(`isConclusive`)ときだけ呼ぶ。以後この (serial, package) では問い合わせも
    /// 警告もしない = 警告は高々1回
    static func markDiagnosed(serial: String, package: String) {
        lock.lock()
        defer { lock.unlock() }
        diagnosed.insert(Key(serial: serial, package: package))
    }

    /// テスト専用: プロセス内メモを空にする
    static func resetDiagnosisMemoForTesting() {
        lock.lock()
        defer { lock.unlock() }
        diagnosed.removeAll()
    }

    private struct Key: Hashable { let serial: String; let package: String }
    private static let lock = NSLock()
    private static var diagnosed = Set<Key>()
}
