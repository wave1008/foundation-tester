// エミュレータ操作の gRPC/adb 振り分け(既定 gRPC・ユーザー決定 2026-07-25)。
// - serial がディスカバリ(EmulatorEndpoints)に無い = 実機 or 旧 emulator → 呼び出し側の adb 経路
// - gRPC が一度でも失敗した個体は同一ブート(pid)中は adb 固定(再試行で遅くしない。
//   再ブートで pid が変われば自動的に gRPC へ復帰)
// - 殺しスイッチ: 環境変数 FT_EMULATOR_CONTROL=adb で全面 adb(docs/verification.md)
// 各メソッドは「gRPC で完了できなければ nil / false」を返し、呼び出し側が adb にフォールバックする。

import FTEmulatorGrpc
import Foundation

public enum EmulatorControl {

    /// gRPC 失敗を記憶した emulator プロセス pid(NSLock 保護。プロセス内メモ)
    private static let memoLock = NSLock()
    private nonisolated(unsafe) static var failedPids: Set<Int32> = []

    static var grpcDisabled: Bool {
        ProcessInfo.processInfo.environment["FT_EMULATOR_CONTROL"] == "adb"
    }

    /// PNG スクリーンショット。nil = gRPC 不可(呼び出し側が adb screencap へ)
    public static func screenshotPNG(serial: String) async -> Data? {
        await perform(serial: serial) { try await EmulatorGrpcSession.screenshotPNG(endpoint: $0) }
    }

    /// sleep/wake 1サイクル(KEY_SLEEP→dwell→KEY_POWER)。false = gRPC 不可
    public static func sleepWake(serial: String, dwellNs: UInt64) async -> Bool {
        await perform(serial: serial) {
            try await EmulatorGrpcSession.sleepWake(endpoint: $0, dwell: .nanoseconds(dwellNs))
        } != nil
    }

    /// 正規シャットダウン(adb 経路死亡でも届く)。false = gRPC 不可
    public static func shutdown(serial: String) async -> Bool {
        await perform(serial: serial) { try await EmulatorGrpcSession.shutdown(endpoint: $0) } != nil
    }

    /// getStatus.booted。nil = gRPC 不可(booted=false は「ブート未完」として有効値)
    public static func statusBooted(serial: String) async -> Bool? {
        await perform(serial: serial) { try await EmulatorGrpcSession.statusBooted(endpoint: $0) }
    }

    /// VM リセット(guest reboot 相当)。false = gRPC 不可
    public static func reset(serial: String) async -> Bool {
        await perform(serial: serial) { try await EmulatorGrpcSession.reset(endpoint: $0) } != nil
    }

    /// 名前付きキー keypress("GoHome"/"AppSwitch" 等)。false = gRPC 不可
    public static func namedKeypress(serial: String, key: String) async -> Bool {
        await perform(serial: serial) {
            try await EmulatorGrpcSession.sendNamedKeypress(endpoint: $0, key: key)
        } != nil
    }

    /// 2点間ドラッグ(座標は screencap と同じ物理ピクセル)。false = gRPC 不可
    public static func drag(serial: String, fromX: Int32, fromY: Int32,
                            toX: Int32, toY: Int32, durationMs: Int) async -> Bool {
        await perform(serial: serial) {
            try await EmulatorGrpcSession.drag(endpoint: $0, fromX: fromX, fromY: fromY,
                                               toX: toX, toY: toY, durationMs: durationMs)
        } != nil
    }

    /// 座標ロングプレス。false = gRPC 不可
    public static func longPress(serial: String, x: Int32, y: Int32, durationMs: Int) async -> Bool {
        await perform(serial: serial) {
            try await EmulatorGrpcSession.longPress(endpoint: $0, x: x, y: y, durationMs: durationMs)
        } != nil
    }

    /// serial → AVD 名(gRPC 不要・ディスカバリファイル読みのみ。`adb emu avd name` の代替)。
    /// 殺しスイッチの対象外(adb を使わない読み取りで、失敗時は呼び出し側が adb に落ちるだけ)
    public static func avdName(serial: String) -> String? {
        EmulatorEndpoints.endpoint(serial: serial)?.avdID
    }

    // MARK: - 内部

    private static func perform<T: Sendable>(
        serial: String, _ op: (EmulatorEndpoint) async throws -> T
    ) async -> T? {
        guard !grpcDisabled,
              let endpoint = EmulatorEndpoints.endpoint(serial: serial),
              !isFailed(pid: endpoint.pid) else { return nil }
        do {
            return try await op(endpoint)
        } catch {
            markFailed(pid: endpoint.pid)
            FileHandle.standardError.write(Data(
                "⚠️ emulator gRPC failed — falling back to adb (\(serial), pid \(endpoint.pid)): \(error)\n".utf8))
            return nil
        }
    }

    private static func isFailed(pid: Int32) -> Bool {
        memoLock.lock()
        defer { memoLock.unlock() }
        return failedPids.contains(pid)
    }

    private static func markFailed(pid: Int32) {
        memoLock.lock()
        defer { memoLock.unlock() }
        failedPids.insert(pid)
    }
}
