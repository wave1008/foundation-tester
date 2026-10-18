/// 計測モードの繰り返し展開(純粋関数)。呼び手は `ProfileRunner` と `ApiRunCommand` の LPT 並べ替えの直後
/// (`fleetest run --profile` と `fleetest api run --profile` の2入口。片方だけに足さない)
public enum ResponseMeasurementRepeat {

    /// 各項目を `count` 個、項目の順のまま連続して並べる(A1..AN, B1..BN)。
    /// **全部のコピーに `repeat=1...N` を付ける**(1回目だけ元の URL にすると、1回目と他の回で
    /// 付け方が変わり、URL を一意キーにする側で「元の URL = 1回目」という暗黙の規則を要求するため)。
    /// `lastPathComponent` はシナリオ ID のまま。`count <= 1` は元の列をそのまま返す
    public static func expand(_ items: [ScenarioRunItem], count: Int) -> [ScenarioRunItem] {
        guard count > 1 else { return items }
        var result: [ScenarioRunItem] = []
        result.reserveCapacity(items.count * count)
        for item in items {
            for index in 1...count {
                result.append(ScenarioRunItem(info: item.info, lane: item.lane, repeatIndex: index))
            }
        }
        return result
    }
}
