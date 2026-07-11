// AndroidDriver.swift
// AppDriver の Android 実装。
// snapshot/tap/type/swipe/press/screenshot/launch/status はデバイス常駐ブリッジ
// (AndroidRunner/、iOS ブリッジとプロトコル互換)を自動起動して HTTP で行う(AndroidBridge.swift)。
// ブリッジに接続できない場合は DriverError.bridgeUnreachable を投げる(フォールバックなし)。
// 操作後の整定待ちはブリッジ側の a11y 静穏検知に委譲する。
// terminate のみ adb 直(currentPackage 管理の意味論を維持)。
// FTAgent(探索・修復・トリアージ)と FTCore(再生器)はドライバ実装に依存しない。

import Foundation
import FTBridgeClient
import FTCore

public final class AndroidDriver: AppDriver {

    public let adbPath: String
    let serial: String?

    // 直近スナップショットの ref → 中心座標(iOS ランナーと同じ方式)。
    // iOS と違い CLI プロセス内に住むため、呼び出しをまたぐ手動駆動用に
    // 一時ファイルへも永続化する(explore/run は単一プロセスなので不要だが無害)
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
        // ブリッジの /status に一本化する(ready 判定にブリッジ疎通を伴わせることで、
        // 「接続不能なら早期に失敗させる」呼び出し元の意図を満たす)
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
        // ブリッジの POST /session に一本化する(force-stop+monkey+am start フォールバックは
        // ブリッジ側 handleLaunch() が持つ。整定待ちもブリッジ側で完結するので
        // ここでの追加 sleep は不要)
        try await withBridge { try await $0.launch(bundleID: bundleID) }
        currentPackage = bundleID
    }

    public func snapshot() async throws -> SnapshotResponse {
        restoreStateIfNeeded()  // 別プロセス実行時に refCenters 等を引き継ぐ(persistState で消さないため)
        let snapshot = try await withBridge { try await $0.snapshot() }
        syncLocalState(from: snapshot)
        return snapshot
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

    /// ブリッジ snapshot の結果をホスト側 ref テーブルにも写す。CLI プロセス跨ぎの手動駆動
    /// (persistState 経由)を守る保険
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

    public func press(ref: Int, duration: Double) async throws {
        restoreStateIfNeeded()
        guard refCenters[ref] != nil else {
            throw DriverError.badResponse(status: 404, body: "参照番号 [\(ref)] は未知です")
        }
        try await withBridge { try await $0.press(ref: ref, duration: duration) }
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

}
