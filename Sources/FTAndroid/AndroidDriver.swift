// AppDriver の Android 実装。
// snapshot/tap/type/swipe/press/screenshot/launch/status はデバイス常駐ブリッジ
// (AndroidRunner/、iOS ブリッジとプロトコル互換)を自動起動して HTTP で行う(AndroidBridge.swift)。
// ブリッジに接続できない場合は DriverError.bridgeUnreachable を投げる(フォールバックなし)。
// 操作後の整定待ちはブリッジ側の a11y 静穏検知に委譲する。
// terminate のみ adb 直(currentPackage 管理の意味論を維持)。
// FTAgent(探索・修復・トリアージ)と FTCore(再生器)はドライバ実装に依存しない。

import CryptoKit
import Foundation
import FTBridgeClient
import FTCore

public final class AndroidDriver: AppDriver {

    public let adbPath: String
    let serial: String?

    // 直近スナップショットの ref → 中心座標(iOS ランナーと同じ方式)。iOS と違い CLI プロセス内に
    // 住むため、呼び出しをまたぐ手動駆動用に一時ファイルへも永続化する(run は単一プロセスで不要だが無害)
    private var refCenters: [Int: (x: Double, y: Double)] = [:]
    private var screen: FTRect = FTRect(x: 0, y: 0, width: 0, height: 0)
    private var currentPackage: String?

    private struct PersistedState: Codable {
        var centers: [Int: [Double]]
        var screen: FTRect
        var package: String?
    }

    private var stateFileURL: URL {
        // WiFi 接続の実機 serial は "192.168.1.23:5555" 形式で ":" を含む。ファイル名に使うと
        // Finder 上で "/" に化けるため、パス区切りになりうる文字は "_" に潰す
        let safeSerial = (serial ?? "default").map { $0 == ":" || $0 == "/" ? "_" : $0 }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-android-\(String(safeSerial)).json")
    }

    func persistState() {
        let state = PersistedState(
            centers: refCenters.mapValues { [$0.x, $0.y] },
            screen: screen, package: currentPackage)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFileURL)
        }
    }

    private func restoreStateIfNeeded() {
        guard refCenters.isEmpty,
              let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        refCenters = state.centers.compactMapValues { $0.count == 2 ? (x: $0[0], y: $0[1]) : nil }
        screen = state.screen
        if currentPackage == nil { currentPackage = state.package }
    }

    public init(serial: String? = nil) throws {
        self.adbPath = try Self.findADB()
        self.serial = serial
    }

    public static func findADB() throws -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["ANDROID_HOME"].map { $0 + "/platform-tools/adb" },
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
        ].compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw DriverError.bridgeUnreachable("adb not found (set ANDROID_HOME)")
    }

    // MARK: - adb helpers

    func adb(_ args: [String]) throws -> Shell.Result {
        var full = [adbPath]
        if let serial { full += ["-s", serial] }
        return try Shell.run(full + args)
    }

    func adbData(_ args: [String]) throws -> Data {
        var full = [adbPath]
        if let serial { full += ["-s", serial] }
        let (status, data) = try Shell.runData(full + args)
        guard status == 0 else {
            throw DriverError.badResponse(status: Int(status), body: "adb \(args.joined(separator: " "))")
        }
        return data
    }

    // MARK: - AppDriver

    public func status() async throws -> StatusResponse {
        // ブリッジの /status に一本化(ready判定にブリッジ疎通を伴わせ、接続不能なら早期に失敗させる)
        try await withBridge { try await $0.status() }
    }

    public func install(packagePath: String) async throws {
        let result = try adb(["install", "-r", packagePath])
        guard result.output.contains("Success") else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to install the app: \(result.tail)")
        }
    }

    public func launch(bundleID: String) async throws {
        // force-stop+monkey+am start フォールバックと整定待ちはブリッジ側 handleLaunch() が持つ
        // (ここでの追加 sleep は不要)
        try await withBridge { try await $0.launch(bundleID: bundleID) }
        // 再起動で旧 snapshot の ref は無効。メモリ・永続化の両方から落とし、
        // 以後の tap(ref:) を「先に snapshot」エラーに倒す(古い座標への誤タップ防止)
        refCenters = [:]
        currentPackage = bundleID
        persistState()
    }

    /// 状態を保持したまま前面化する。ブリッジの launch(force-stop+再起動)は使わず adb 直で

    /// ブリッジを経由せず画面を変えた後の整定。**ブリッジの QuietWaiter(a11y イベント駆動)**を
    /// 呼ぶ(プッシュ型。performance-tuning.md §2 の第1原則)。
    ///
    /// 旧実装は一律 800ms の固定 sleep だった。固定値はマシン性能・並列負荷・アニメーション長で
    /// 過不足が出る(iOS 側で同じ問題を実測した。§3.8)。ブリッジが応答しない・旧版(v19 未満)で
    /// ルートが無い等で失敗したときだけ、従来と同じ 800ms へ落ちる(整定ゼロで進むと直後の
    /// snapshot が遷移前の画面を掴むため、黙って素通ししない)。
    private func settleViaBridge() async {
        do {
            try await withBridge { try await $0.settle() }
        } catch {
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    /// ランチャー intent を送る(起動中ならタスクが前面に来るだけ)。
    public func activate(bundleID: String) async throws {
        let result = try adb(["shell", "monkey", "-p", bundleID,
                              "-c", "android.intent.category.LAUNCHER", "1"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to bring the app to the foreground: \(result.tail)")
        }
        // monkey は intent 送信のみで遷移完了を待たないため、直後の snapshot が遷移前の画面を
        // 掴まないよう整定を待つ(settleViaBridge)
        await settleViaBridge()
        restoreStateIfNeeded()  // 状態保持の前面化なので refs は維持(空の状態で persist して消さない)
        currentPackage = bundleID
        persistState()
    }

    /// タスク一覧(最近使ったアプリ)を開く。gRPC "AppSwitch"(proto が Overview 動作を明記)優先・
    /// adb keyevent フォールバック。
    public func openAppSwitcher() async throws {
        if let serial, await EmulatorControl.namedKeypress(serial: serial, key: "AppSwitch") {
            // gRPC 成功
        } else {
            let result = try adb(["shell", "input", "keyevent", "KEYCODE_APP_SWITCH"])
            guard result.status == 0 else {
                throw DriverError.badResponse(status: Int(result.status),
                    body: "failed to open the app switcher: \(result.tail)")
            }
        }
        // keyevent は遷移完了を待たないため、直後の snapshot 用の整定待ち(activate と同様)
        await settleViaBridge()
    }

    /// ホーム画面に戻る。gRPC "GoHome" 優先・adb keyevent フォールバック。
    public func home() async throws {
        if let serial, await EmulatorControl.namedKeypress(serial: serial, key: "GoHome") {
            // gRPC 成功
        } else {
            let result = try adb(["shell", "input", "keyevent", "KEYCODE_HOME"])
            guard result.status == 0 else {
                throw DriverError.badResponse(status: Int(result.status),
                    body: "failed to go to the home screen: \(result.tail)")
            }
        }
        // keyevent は遷移完了を待たないため、直後の snapshot 用の整定待ち(openAppSwitcher と同様)
        await settleViaBridge()
    }

    public func snapshot() async throws -> SnapshotResponse {
        restoreStateIfNeeded()  // 別プロセス実行時に refCenters 等を引き継ぐ(persistState で消さないため)
        let snapshot = try await withBridge { try await $0.snapshot() }
        syncLocalState(from: snapshot)
        return snapshot
    }

    /// システムロケールの永続変更(ブリッジ /locale。ブート完了後に呼ぶこと)。
    /// 既に一致していれば changed=false の no-op(フレームワーク再起動なし)
    public func setDeviceLocale(_ locale: String) async throws -> BridgeClient.DeviceLocaleResponse {
        try await withBridge { try await $0.setDeviceLocale(locale) }
    }

    public func tap(ref: Int) async throws {
        restoreStateIfNeeded()
        guard let center = refCenters[ref] else {
            throw DriverError.badResponse(status: 404, body: "unknown reference number [\(ref)]. Take a snapshot first")
        }
        try await tap(x: center.0, y: center.1)
    }

    public func tap(x: Double, y: Double) async throws {
        try await withBridge { try await $0.tap(x: x, y: y) }
    }

    /// ブリッジ snapshot の結果をホスト側 ref テーブルにも写す(CLI プロセス跨ぎの手動駆動を保つ)
    private func syncLocalState(from snapshot: SnapshotResponse) {
        var centers: [Int: (x: Double, y: Double)] = [:]
        for element in snapshot.elements {
            centers[element.ref] = (x: element.frame.centerX, y: element.frame.centerY)
        }
        refCenters = centers
        screen = snapshot.screen
        persistState()
    }

    public func type(ref: Int?, text: String) async throws {
        // ref は**ブリッジまで通す**(ホスト側で tap+ref:nil に分解しない)。分解すると
        // ブリッジは「フォーカス中のフィールドへ注入」(findFocus)しかできず、直前の scene で
        // 別フィールドがフォーカスを保持している+フォーカス遷移が負荷で遅れた実行で
        // 旧フィールドへ誤追記する(hello123secret42 事故)。ブリッジの ref 経路
        // (InputInjector.setTextAppendingAt)は「タップ点にある editable ノードそのもの」へ
        // SET_TEXT + 期限内リトライするため、誤爆が構造的に起きない。
        // v10-v12 のブリッジ側修正がここの分解のせいで一度も実行されていなかった(2026-07-23)。
        //
        // 末尾の改行1つは ACTION_SET_TEXT では文字として入るだけで IME アクションにならないため、
        // 分離して本文の SET_TEXT 後に Enter キーイベントを送る(pressEnter と同じ経路。文中の
        // 改行はそのまま文字として本文に残す)
        let (main, hasTrailingNewline) = Self.splitTrailingNewline(text)
        guard hasTrailingNewline else {
            try await withBridge { try await $0.type(ref: ref, text: text) }
            return
        }
        // 本文が空でも ref があれば SET_TEXT を通し、対象ノードへのフォーカス確立を維持する
        try await withBridge { try await $0.type(ref: ref, text: main) }
        try await pressEnter()
    }

    /// 末尾の改行1つだけを分離する(text 全体が "\n" のときは分離しない=本文なしの pressEnter 相当に
    /// 潰さない)。戻り値: (本文, 末尾に改行があったか)
    static func splitTrailingNewline(_ text: String) -> (String, Bool) {
        guard text != "\n", text.hasSuffix("\n") else { return (text, false) }
        return (String(text.dropLast()), true)
    }

    /// Enter キーを押す(フォーカス中の入力欄への IME アクション相当)。ブリッジの /pressEnter
    /// (ACTION_IME_ENTER)を優先する: ソフトキーボード表示中の View/XML EditText では keyevent 66
    /// が IME に吸われ OnEditorActionListener に届かない(Compose は独自のキーイベント処理経路の
    /// ため keyevent でも発火する。実機実測で確認済み)。404(旧ブリッジ未実装)/409(フォーカス無し
    /// 等)/501(API 30未満)は下のキーイベント経路へフォールバックする。bridgeConnectionRefused
    /// 等それ以外のエラーは握り潰さずそのまま投げる。
    public func pressEnter() async throws {
        do {
            try await withBridge { try await $0.pressEnter() }
            return
        } catch let error as DriverError {
            guard case .badResponse(let status, _) = error,
                  status == 404 || status == 409 || status == 501 else { throw error }
        }
        // gRPC KeyboardEvent.key は w3c 名(home()/openAppSwitcher() と同じ振り分け)。"Enter" は
        // w3c UIEvents キー値だが emulator gRPC 側の対応は未確認 — EmulatorControl.perform は
        // 失敗時 false を返すだけなので、未対応でも adb フォールバックへ落ちるだけで安全
        if let serial, await EmulatorControl.namedKeypress(serial: serial, key: "Enter") {
            // gRPC 成功
        } else {
            let result = try adb(["shell", "input", "keyevent", "66"])
            guard result.status == 0 else {
                throw DriverError.badResponse(status: Int(result.status),
                    body: "failed to send the Enter key: \(result.tail)")
            }
        }
        // keyevent は遷移完了を待たないため、直後の snapshot 用の整定待ち(home() と同様)。
        // ブリッジ経路はサーバ側 settle() 込みで応答するため不要
        await settleViaBridge()
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await withBridge { try await $0.swipe(direction) }
    }

    /// 2点間ドラッグ。ブリッジ経由ではなく gRPC タッチ合成(down→補間 move→up)優先・
    /// adb input swipe フォールバック(どちらも snapshot と同じピクセル座標)。
    /// gRPC はゲスト内 app_process 起動(~300ms/回)が無くステップ列が高速。
    /// pressSeconds は対応がなく未使用。durationSeconds を duration(ms)へ変換し 50〜10000ms にクランプ。
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        let durationMs = min(max(Int((durationSeconds * 1000).rounded()), 50), 10000)
        if let serial, await EmulatorControl.drag(serial: serial,
                                      fromX: Int32(fromX.rounded()), fromY: Int32(fromY.rounded()),
                                      toX: Int32(toX.rounded()), toY: Int32(toY.rounded()),
                                      durationMs: durationMs) {
            return
        }
        let result = try adb(["shell", "input", "swipe",
                              String(Int(fromX.rounded())), String(Int(fromY.rounded())),
                              String(Int(toX.rounded())), String(Int(toY.rounded())),
                              String(durationMs)])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "drag failed: \(result.tail)")
        }
    }

    public func press(ref: Int, duration: Double) async throws {
        restoreStateIfNeeded()
        guard let center = refCenters[ref] else {
            throw DriverError.badResponse(status: 404, body: "unknown reference number [\(ref)]. Take a snapshot first")
        }
        // tap(ref:) と同じくホスト側で座標解決してブリッジへは x/y で送る(ブリッジ再起動で
        // ブリッジ側 ref 表だけが消えてもずれない。注入経路は従来と同じ InputInjector.press)。
        // ブリッジ v8 以降が前提(v7 は /press が ref 必須。probe の版照合で自動更新される)
        try await withBridge { try await $0.press(x: center.x, y: center.y, duration: duration) }
    }

    /// 座標ロングプレス。gRPC タッチ(down→保持→up)優先・同一点 input swipe フォールバック。
    public func press(x: Double, y: Double, duration: Double) async throws {
        let durationMs = min(max(Int((duration * 1000).rounded()), 300), 10000)
        if let serial, await EmulatorControl.longPress(serial: serial, x: Int32(x.rounded()),
                                           y: Int32(y.rounded()), durationMs: durationMs) {
            return
        }
        let px = String(Int(x.rounded()))
        let py = String(Int(y.rounded()))
        let result = try adb(["shell", "input", "swipe", px, py, px, py, String(durationMs)])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "long-press failed: \(result.tail)")
        }
    }

    public func screenshot() async throws -> Data {
        try await withBridge { try await $0.screenshot() }
    }

    public func terminate() async throws {
        restoreStateIfNeeded()
        if let package = currentPackage {
            _ = try adb(["shell", "am", "force-stop", package])
            currentPackage = nil
            persistState()  // 消さないと別プロセスの再 terminate が古い package を force-stop する
        }
    }

    /// インストール済み APK が apkPath と同一内容か(adb install は base.apk をそのままコピーする
    /// ため md5 一致で判定できる。autoInstall の差分スキップ用)。未インストール・判定不能は
    /// false(=要インストール)。
    public func installedPackageIsCurrent(packageID: String, apkPath: String) -> Bool {
        guard let pathResult = try? adb(["shell", "pm", "path", packageID]),
              pathResult.status == 0 else { return false }
        guard let remote = pathResult.output.split(separator: "\n")
            .first(where: { $0.hasPrefix("package:") })
            .map({ String($0.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces) }),
            !remote.isEmpty else { return false }
        guard let md5Result = try? adb(["shell", "md5sum", remote]), md5Result.status == 0,
              let remoteHash = md5Result.output.split(separator: " ").first.map(String.init) else {
            return false
        }
        guard let localData = try? Data(contentsOf: URL(fileURLWithPath: apkPath)) else { return false }
        let localHash = Insecure.MD5.hash(data: localData).map { String(format: "%02x", $0) }.joined()
        return remoteHash.lowercased() == localHash
    }

    /// インストール済みのユーザーアプリ(third-party)のパッケージ名一覧。
    public func listInstalledPackages() throws -> [String] {
        let result = try adb(["shell", "pm", "list", "packages", "-3"])
        return result.output.split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("package:") ? String(trimmed.dropFirst("package:".count)) : nil
            }
            .sorted()
    }

}
