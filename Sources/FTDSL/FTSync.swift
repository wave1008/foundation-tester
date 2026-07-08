// FTSync.swift
// 同期ファサードの心臓部。DSL コマンドは専用スレッド(協調スレッドプール外)で同期実行され、
// async の StepExecutor/AppDriver へはここで橋渡しする。
// ブロックするのは DSL 専用スレッドのみで、async 側(URLSession/Process/FoundationModels)は
// このスレッドを必要としないためデッドロックしない。
// 万一のハングに備え、待機には上限タイムアウトを設ける。

import Foundation

enum FTSync {
    /// コマンド 1 回の上限待機秒数
    static var commandTimeout: TimeInterval = 120

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    /// async 処理を実行して完了まで現在スレッドをブロックする。タイムアウト時は nil
    static func run<T>(timeout: TimeInterval = FTSync.commandTimeout,
                       _ op: @escaping () async -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached(priority: .userInitiated) {
            box.value = await op()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    /// throwing 版。タイムアウト時は nil、それ以外は Result
    static func runThrowing<T>(timeout: TimeInterval = FTSync.commandTimeout,
                               _ op: @escaping () async throws -> T) -> Result<T, Error>? {
        run(timeout: timeout) {
            do { return .success(try await op()) } catch { return .failure(error) }
        }
    }
}
