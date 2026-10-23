// ResolvedPinSync.swift
// 受け手のパッケージ(WORK_DIR)の Package.resolved に、パス依存の先(fleetest のクローン)の版の固定を写す。
// 写さないと受け手は依存の版を独自に解決し直す: ①fleetest がテストした組と違う版で組まれる(swift-syntax 603 → 604 を実測)
// ②最初のシナリオのビルドで全依存の版を計算し直す(約 42 秒。固定した版だけで解決すると約 15 秒)。
// 呼び手は `fleetest init`(新しい受け手)と `fleetest project sync`(update.sh が毎回呼ぶ = 既存の受け手とクローンの更新)。

import Foundation

public enum ResolvedPinSync {

    /// 受け手の Package.resolved(無ければ nil)にクローンの固定を重ねる。同じ identity はクローンの版で置き換え、
    /// 受け手だけが持つ固定(シナリオの追加依存)は残す。変わらなければ nil。どちらかが読めなければ nil(触らない)
    public static func merged(consumer: Data?, tool: Data) -> Data? {
        guard let toolObject = try? JSONSerialization.jsonObject(with: tool) as? [String: Any],
              let toolPins = toolObject["pins"] as? [[String: Any]] else { return nil }
        var base = toolObject
        var pinsByIdentity: [String: [String: Any]] = [:]
        if let consumer {
            guard let consumerObject = try? JSONSerialization.jsonObject(with: consumer) as? [String: Any],
                  let consumerPins = consumerObject["pins"] as? [[String: Any]] else { return nil }
            base = consumerObject
            for pin in consumerPins {
                if let identity = pin["identity"] as? String { pinsByIdentity[identity] = pin }
            }
        }
        var changed = consumer == nil
        for pin in toolPins {
            guard let identity = pin["identity"] as? String else { continue }
            if let existing = pinsByIdentity[identity], NSDictionary(dictionary: existing).isEqual(to: pin) { continue }
            pinsByIdentity[identity] = pin
            changed = true
        }
        guard changed else { return nil }
        base["pins"] = pinsByIdentity.keys.sorted().compactMap { pinsByIdentity[$0] }
        return try? JSONSerialization.data(withJSONObject: base, options: [.prettyPrinted, .sortedKeys])
    }

    /// packageRoot の Package.swift が指すパス依存の先の Package.resolved を packageRoot へ重ねる。
    /// 書いたら true。パス依存が無い(クローン構成・url 依存)・先に Package.resolved が無いなら何もしない
    @discardableResult
    public static func sync(packageRoot: URL) throws -> Bool {
        let destination = packageRoot.appendingPathComponent("Package.resolved")
        var current = try? Data(contentsOf: destination)
        var wrote = false
        for dependencyRoot in BuildFingerprint.pathDependencyRoots(repoRoot: packageRoot) {
            guard let tool = try? Data(contentsOf: dependencyRoot.appendingPathComponent("Package.resolved")),
                  let next = merged(consumer: current, tool: tool) else { continue }
            try next.write(to: destination, options: .atomic)
            current = next
            wrote = true
        }
        return wrote
    }

    /// まだ一度も解決していない(`.build/workspace-state.json` が無い)パッケージで、Package.resolved があるとき true。
    /// このときだけ `swift package resolve --only-use-versions-from-resolved-file` を先に撃つ
    /// (素の swift build は固定があっても全依存の版を計算し直す。解決済みのパッケージに撃つと毎回の所要が増えるだけ)
    public static func pinnedResolveNeeded(packageRoot: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: packageRoot.appendingPathComponent("Package.resolved").path)
            && !fm.fileExists(atPath: packageRoot.appendingPathComponent(".build/workspace-state.json").path)
    }
}
