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
    // 住むため、呼び出しをまたぐ手動駆動用に一時ファイルへも永続化する(explore/run は単一プロセスで不要だが無害)
    private var refCenters: [Int: (x: Double, y: Double)] = [:]
    private var screen: FTRect = FTRect(x: 0, y: 0, width: 0, height: 0)
    private var currentPackage: String?

    private struct PersistedState: Codable {
        var centers: [Int: [Double]]
        var screen: FTRect
        var package: String?
    }

    private var stateFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-android-\(serial ?? "default").json")
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
        throw DriverError.bridgeUnreachable("adb が見つかりません(ANDROID_HOME を設定してください)")
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
                body: "アプリのインストールに失敗しました: \(result.tail)")
        }
    }

    public func launch(bundleID: String) async throws {
        // force-stop+monkey+am start フォールバックと整定待ちはブリッジ側 handleLaunch() が持つ
        // (ここでの追加 sleep は不要)
        try await withBridge { try await $0.launch(bundleID: bundleID) }
        currentPackage = bundleID
    }

    /// 状態を保持したまま前面化する。ブリッジの launch(force-stop+再起動)は使わず adb 直で
    /// ランチャー intent を送る(起動中ならタスクが前面に来るだけ)。
    public func activate(bundleID: String) async throws {
        let result = try adb(["shell", "monkey", "-p", bundleID,
                              "-c", "android.intent.category.LAUNCHER", "1"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "アプリを前面化できませんでした: \(result.tail)")
        }
        // monkey は intent 送信のみで遷移完了を待たないため、直後の snapshot が遷移前の画面を
        // 掴まない程度の整定待ち
        try await Task.sleep(nanoseconds: 800_000_000)
        currentPackage = bundleID
    }

    /// タスク一覧(最近使ったアプリ)を開く。
    public func openAppSwitcher() async throws {
        let result = try adb(["shell", "input", "keyevent", "KEYCODE_APP_SWITCH"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "タスク一覧を開けませんでした: \(result.tail)")
        }
        // keyevent は遷移完了を待たないため、直後の snapshot 用の整定待ち(activate と同様)
        try await Task.sleep(nanoseconds: 800_000_000)
    }

    /// ホーム画面に戻る。
    public func home() async throws {
        let result = try adb(["shell", "input", "keyevent", "KEYCODE_HOME"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "ホーム画面に戻れませんでした: \(result.tail)")
        }
        // keyevent は遷移完了を待たないため、直後の snapshot 用の整定待ち(openAppSwitcher と同様)
        try await Task.sleep(nanoseconds: 800_000_000)
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
            throw DriverError.badResponse(status: 404, body: "参照番号 [\(ref)] は未知です。先に snapshot を実行してください")
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
        if let ref {
            try await tap(ref: ref)  // ref はホスト側で座標解決(タップ自体の整定待ちはブリッジ側で完了済み)
        }
        try await withBridge { try await $0.type(ref: nil, text: text) }  // ACTION_SET_TEXT(日本語も IME 不要)
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await withBridge { try await $0.swipe(direction) }
    }

    /// 2点間ドラッグ。ブリッジ経由ではなく adb 直(input swipe は snapshot と同じピクセル座標)。
    /// pressSeconds は input swipe に対応がなく未使用。durationSeconds を input swipe の duration(ms)へ
    /// 変換し 50〜10000ms にクランプする。
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        let durationMs = min(max(Int((durationSeconds * 1000).rounded()), 50), 10000)
        let result = try adb(["shell", "input", "swipe",
                              String(Int(fromX.rounded())), String(Int(fromY.rounded())),
                              String(Int(toX.rounded())), String(Int(toY.rounded())),
                              String(durationMs)])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "ドラッグに失敗しました: \(result.tail)")
        }
    }

    public func press(ref: Int, duration: Double) async throws {
        restoreStateIfNeeded()
        guard refCenters[ref] != nil else {
            throw DriverError.badResponse(status: 404, body: "参照番号 [\(ref)] は未知です")
        }
        try await withBridge { try await $0.press(ref: ref, duration: duration) }
    }

    /// 座標ロングプレス。同一点への input swipe が Android の標準的な長押し合成手段。
    public func press(x: Double, y: Double, duration: Double) async throws {
        let durationMs = min(max(Int((duration * 1000).rounded()), 300), 10000)
        let px = String(Int(x.rounded()))
        let py = String(Int(y.rounded()))
        let result = try adb(["shell", "input", "swipe", px, py, px, py, String(durationMs)])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "ロングプレスに失敗しました: \(result.tail)")
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
