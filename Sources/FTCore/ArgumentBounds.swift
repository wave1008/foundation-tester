// ArgumentBounds.swift
// MCP(ft_*)とライブ操作(api live serve)が共有する引数の値域チェック(唯一の定義元)。
// 型検査(intArgument/doubleArgument/stringField 等)は呼び手側にあり、ここは
// 「型は合っているが値が無意味」(0/負・空文字)を断る。lastN の個別検査がこの型の唯一の
// 先例だった(MCPServer+Draft.swift)—— 他の引数には掃討されていなかった。

import Foundation

public enum ArgumentBounds {

    /// 数値引数1つの値域。**下限・上限のどちらも無ければ `.unbounded`**
    /// (座標・ref のように「画面内か」を別の門が見る引数はここでは縛らない)
    public struct Bound: Sendable, Equatable {
        public let min: Double?
        public let minExclusive: Bool
        public let max: Double?
        public let maxExclusive: Bool

        public init(min: Double? = nil, minExclusive: Bool = false,
                    max: Double? = nil, maxExclusive: Bool = false) {
            self.min = min
            self.minExclusive = minExclusive
            self.max = max
            self.maxExclusive = maxExclusive
        }

        public static let unbounded = Bound()
    }

    /// hold/gesture 系(holdSeconds・durationSeconds・duration・press)と `maxGestureSeconds` の
    /// **表での**上限は絶対上限 `BridgeAPI.gestureSecondsCeiling`(60)。1回の呼び出しで実際に許すのは
    /// 既定 `BridgeAPI.defaultMaxGestureSeconds`(10)か、渡された `maxGestureSeconds` まで ——
    /// その相互検査は `gestureCapViolation`(表の単独検査では書けない)
    private static let gestureSecondsCeiling = BridgeAPI.gestureSecondsCeiling

    /// 引数名 → 値域。**値域を持たない引数も `.unbounded` で必ず載せる** ——
    /// スキーマの数値プロパティ全部がここに載っていることを `ArgumentBoundsTests` が
    /// 走査で確かめる(載せ忘れは「値域が無いから」ではなく「まだ検討していないから」を
    /// 区別できない)。
    ///
    /// `duration` / `press`(api live serve のワイヤの欄名。MCP のスキーマには出ない)は
    /// `durationSeconds` と同じ値域を共有する。`waitSeconds` は MCP ツールの待ち上限と
    /// `ft_batch` の DSL 行の両方が使う(同じ名前・同じ値域)。`repeat` / `dxRatio` / `dyRatio`
    /// は `ft_batch` の DSL 行だけが使う鍵(BatchStepResolver.intKeys/doubleKeys)
    public static let numeric: [String: Bound] = [
        "lines": Bound(min: 1),
        "sinceSeconds": Bound(min: 1),
        "maxElements": Bound(min: 1, max: Double(BridgeAPI.maxSnapshotElementsCeiling)),
        "maxSwipes": Bound(min: 0),
        "lastN": Bound(min: 1),
        "maxWidth": Bound(min: 1),
        "quality": Bound(min: 0, minExclusive: true, max: 1),
        "holdSeconds": Bound(min: 0, minExclusive: true, max: gestureSecondsCeiling),
        "durationSeconds": Bound(min: 0, minExclusive: true, max: gestureSecondsCeiling),
        "duration": Bound(min: 0, minExclusive: true, max: gestureSecondsCeiling),
        "press": Bound(min: 0, minExclusive: true, max: gestureSecondsCeiling),
        "maxGestureSeconds": Bound(min: 0, minExclusive: true, max: gestureSecondsCeiling),
        "radius": Bound(min: 0, minExclusive: true),
        "scale": Bound(min: 0, minExclusive: true),
        "port": Bound(min: 1, max: 65535),
        "waitSeconds": Bound(min: 0),
        "repeat": Bound(min: 1),
        "ref": .unbounded,
        "fromRef": .unbounded,
        "x": .unbounded,
        "y": .unbounded,
        "dx": .unbounded,
        "dy": .unbounded,
        "fromX": .unbounded,
        "fromY": .unbounded,
        "toX": .unbounded,
        "toY": .unbounded,
        // ft_batch の swipePointToPoint(座標は x / y と同じ扱い)
        "startX": .unbounded,
        "startY": .unbounded,
        "endX": .unbounded,
        "endY": .unbounded,
        // 負が正しい向きを表す(反対側へ動かす)ので縛らない
        "dxRatio": .unbounded,
        "dyRatio": .unbounded,
    ]

    /// 空文字(空白のみを含む)を断る文字列引数。省略(キー自体が無い)は対象外 ——
    /// 呼び手ごとに「省略時の既定」が違う(フォーカス中の欄・セッションが繋がっているアプリ等)ので、
    /// ここで断るのは「明示したのに空」だけ
    public static let mustNotBeEmpty: Set<String> = [
        "bundleId", "bundle", "url", "packagePath", "path", "id", "selector", "steps",
        "label", "classifier", "name",
    ]

    /// 違反なら文言、範囲内(または値域を持たない引数)なら nil
    public static func violation(_ key: String, _ value: Double) -> String? {
        guard let bound = numeric[key] else { return nil }
        if let min = bound.min {
            if bound.minExclusive {
                guard value > min else {
                    return "\(key) must be greater than \(format(min)) (got \(format(value)))"
                }
            } else {
                guard value >= min else {
                    return "\(key) must be \(format(min)) or more (got \(format(value)))"
                }
            }
        }
        if let max = bound.max {
            if bound.maxExclusive {
                guard value < max else {
                    return "\(key) must be less than \(format(max)) (got \(format(value)))"
                }
            } else {
                guard value <= max else {
                    return "\(key) must be \(format(max)) or less (got \(format(value)))"
                }
            }
        }
        return nil
    }

    /// 違反なら文言、OK(空でない、または断る対象の鍵ではない)なら nil
    public static func emptyViolation(_ key: String, _ value: String) -> String? {
        guard mustNotBeEmpty.contains(key) else { return nil }
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "\(key) must not be empty"
    }

    /// hold/gesture 系の秒数引数(holdSeconds/durationSeconds/duration/press)が
    /// `maxGestureSeconds`(省略時は既定 `BridgeAPI.defaultMaxGestureSeconds` = 10 秒)を
    /// 超えていないかの**相互検査**(単独の `violation` は型/絶対上限のスキーマ検査しかできない)。
    /// **MCPServer.call の入口(`checkArgumentBounds` の隣)と、ライブ操作(`ApiLiveServeCommand.init`)
    /// の両方から呼ぶ**。中身は `BridgeAPI` の2関数(唯一の定義元)を呼ぶだけ
    public static let gestureSecondsKeys: Set<String> = ["holdSeconds", "durationSeconds", "duration", "press"]

    public static func gestureCapViolation(_ args: [String: Any]) -> String? {
        func numeric(_ key: String) -> Double? {
            switch args[key] {
            case let intValue as Int: return Double(intValue)
            case let doubleValue as Double: return doubleValue
            default: return nil
            }
        }
        if let override = numeric("maxGestureSeconds"),
           let violation = BridgeAPI.maxGestureSecondsViolation(override) {
            return violation
        }
        let cap = numeric("maxGestureSeconds") ?? BridgeAPI.defaultMaxGestureSeconds
        for key in gestureSecondsKeys {
            guard let seconds = numeric(key),
                  let violation = BridgeAPI.gestureSecondsViolation(subject: key, seconds: seconds, cap: cap) else { continue }
            return violation
        }
        return nil
    }

    /// 整数値は小数点無しで出す("got 0" であって "got 0.0" ではない)。
    /// **Int の表現範囲に入るときだけ畳む** —— `Int(1e30)` は trap するので、
    /// 桁外れの値(`quality: 1e30` のような打鍵)でサーバごと落とさない
    private static func format(_ value: Double) -> String {
        guard value.isFinite, value == value.rounded(),
              value >= -9007199254740992, value <= 9007199254740992 else {
            return String(value)
        }
        return String(Int(value))
    }
}
