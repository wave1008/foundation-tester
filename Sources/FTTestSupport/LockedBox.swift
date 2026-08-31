import Foundation

/// テストで @Sendable クロージャから記録するための箱(NSLock で守る)。
/// production の値の正規化・整形はしない(テストが production の代わりをしてはいけない)
public final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    public init(_ value: Value) { storage = value }
    public var value: Value { lock.withLock { storage } }
    public func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
