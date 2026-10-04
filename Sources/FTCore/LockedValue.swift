// LockedValue.swift
// 並行に走るクロージャ(concurrentPerform・URLSession の完了・readabilityHandler・Task)と
// 呼び手の間で1つの値を受け渡す箱。Swift 6 は捕捉した `var` の並行な読み書きを止めるので、
// その置き換え先(テストの `FTTestSupport.LockedBox` と同じ役割の production 版)。
// **期限つきの待ち(semaphore.wait(timeout:))の後で読む値は必ずこれを通す** —— 期限切れの後も
// 完了ハンドラは遅れて書きに来る。

import Foundation
import Synchronization

public final class LockedValue<Value>: Sendable {
    private let storage: Mutex<Value>

    public init(_ value: sending Value) { storage = Mutex(value) }

    /// 読みと書きを1回の取得で行う。**本体から同じ箱を触らない**(再入しない)
    public func withLock<R>(_ body: (inout sending Value) throws -> sending R) rethrows -> sending R {
        try storage.withLock(body)
    }
}

extension LockedValue where Value: Sendable {
    public var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// スレッド安全の契約が無いコールバック(呼び手の log・emit)を、並行な呼び出し元へ渡せる形にする。
/// 呼び出しは1本ずつ(再帰ロック = コールバックの中から同じ口を呼んでも詰まらない)。
/// @unchecked の根拠 = `body` は常に lock の下でしか呼ばれない
public final class SerializedSink<Value>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let body: (Value) -> Void

    public init(_ body: @escaping (Value) -> Void) { self.body = body }

    public func callAsFunction(_ value: Value) { lock.withLock { body(value) } }
}

/// 非 Sendable の値(主に `AppDriver`)を子タスクへ渡す包み。@unchecked の根拠は呼び手が守る ——
/// **渡した側は、そのタスクが終わる(await で合流する)まで同じ値に触らない**。並行に触る形には使わない
public struct UncheckedTransfer<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
