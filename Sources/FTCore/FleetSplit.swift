// FleetSplit.swift
// `ftester run --fleet <name> --split`(docs/remote-runner.md §8「シナリオバッチを複数 Mac に
// 割り当てる」)の純粋ロジック。実績の中央値は既存の LPTScheduler.Duration / durations(from:) を
// そのまま使う(中央値算出を二重に持たない)。ssh・プロセス起動・ローカルビルド・ホスト→
// platform の解決は呼び出し側(Sources/ftester/FleetRunner.swift)に置く。
//
// LPT(longest processing time first)貪欲法: 見積りの長いシナリオから、その時点の負荷合計が
// 最小の"適合する"エントリへ入れる。同着は決定的に解く(負荷合計の同点は entryIndex 昇順、
// 見積り時間の同点は scenario ID 昇順) —— 同じ入力から run のたびに違う割り当てが出ると、
// flake 調査で「前回と同じ割り当て」を再現できなくなる。
//
// platform 適合を守らない割り当ては「走ったつもりで走っていない」を静かに作るので、
// 適合するエントリが1つも無いシナリオは黙って落とさず throw する。**ただし「宣言した platform の
// 台が fleet に1台も無い」シナリオは対象外**(単機の run と同じ PlatformApplicability の規律)——
// 呼び手は partition の前に `applicability(scenarios:entryPlatforms:)` で外し、notApplicable を
// スキップとして出す。ここで throw するのは設定ミス(platform 未宣言なのに受けるエントリが無い)だけ。
// 2026-08-23 まで対象外も throw していたため、iOS だけの混在プロファイルに Android 宣言が1本あると
// 1本も走らなかった(受け手報告)
//
// 実績が無いシナリオの見積り(unknownDurationMs)は呼び出し側が決める。プロジェクトごとに
// 実行速度が大きく違うので、固定の秒数をここに埋め込まない(別の文脈で調整した定数の流用は
// 誤った推定を生む。記憶: context-blind-constants-20260815)。
//
// **見積りは「そのエントリが実際に回す platform」の実績だけで作る**(2026-08-24)。
// 同じ scenarioID が ios と android の両方で走るプロジェクトでは、機械別の実績が片 platform に
// 偏る —— ある機械が直近 android でしか回していなければ、その機械の中央値は android のものになる。
// 全 platform の max を採ると「その機械の同一機実績」として android の値が ios の run へ入り、
// **速い platform の値で遅い platform を見積もって一番遅い機械へ最も多く配る**。
// 実データ(受け手の 98 本 iOS run・3機)では M1Ultra だけが android 由来の見積りを 9 本ぶん掴み、
// レーン当たり実績 552 秒に対して推定 448 秒(-19%)で最後まで走る極になっていた。scope を
// 掛けると推定 511 秒(-7%)。**両 platform を回すエントリでは scope が両方 = 従来の max と同一**
// なので、狭まるのは「そちらの platform を回せないエントリ」だけ。

import Foundation

public enum FleetSplit {

    /// 1エントリへの割り当て結果。scenarioIDs は投入順(見積り降順)のまま保持する ——
    /// 呼び出し側がそのまま --scenario へ渡せば、そのエントリ内でも長い順に投入される
    public struct Bucket: Equatable, Sendable {
        public let entryIndex: Int
        public let scenarioIDs: [String]
        public let estimatedMs: Double

        public init(entryIndex: Int, scenarioIDs: [String], estimatedMs: Double) {
            self.entryIndex = entryIndex
            self.scenarioIDs = scenarioIDs
            self.estimatedMs = estimatedMs
        }
    }

    /// 割り当て1エントリぶんの「見積りが何に基づいたか」。partition が assign と同時に数える
    /// (どの分岐を通ったかは割り当てが決まらないと分からないので、後から作り直せない)。
    /// 用途はディスパッチ時のログ1行だけ —— 受け手が「その機械の係数がどこから来たか」を
    /// 結果と突き合わせられるようにする(2026-08-24 受け手要望)。
    public struct EstimateBasis: Equatable, Sendable {
        public let entryIndex: Int
        /// 実績レコードの machine(不明なら nil)
        public let machine: String?
        /// 同一機・同一 platform の実績をそのまま使った本数
        public let ownHistory: Int
        /// 混合実績 × 係数で見積もった本数
        public let scaled: Int
        /// 実績が1件も無く unknownDurationMs × 係数へ落ちた本数
        public let unknown: Int
        /// 同一機実績が無いシナリオに掛かる係数(1.0 = 補正なし)
        public let coefficient: Double
        public let coefficientSource: CoefficientSource

        public init(entryIndex: Int, machine: String?, ownHistory: Int, scaled: Int, unknown: Int,
                    coefficient: Double, coefficientSource: CoefficientSource) {
            self.entryIndex = entryIndex
            self.machine = machine
            self.ownHistory = ownHistory
            self.scaled = scaled
            self.unknown = unknown
            self.coefficient = coefficient
            self.coefficientSource = coefficientSource
        }

        /// ログ1行の断片。**文言はここ1箇所**(DeviceHostRunner と FleetRunner が同じ事実を
        /// 別の言い方で出すと、同じ run の2つの表で係数が食い違って見える)
        public var summary: String {
            var parts: [String] = []
            if ownHistory > 0 {
                parts.append("\(ownHistory) from \(machine ?? "own") history")
            }
            let derived = scaled + unknown
            if derived > 0 {
                parts.append("\(derived) scaled x\(String(format: "%.2f", coefficient))"
                    + " (\(coefficientSource.rawValue))")
            }
            return parts.isEmpty ? "no scenarios" : parts.joined(separator: ", ")
        }
    }

    /// 係数の由来。**measured(実測比)> hardware(コア数比の事前係数)> none(補正なし)** の順に
    /// 強い。measured は「同一機と混合の共通観測」から出るので、機械を跨いで走らせるほど育つ。
    public enum CoefficientSource: String, Sendable, Equatable {
        case measured
        case hardware
        case none
    }

    /// エントリごとの機械情報。すべて entryPlatforms と同じ並び・同じ本数(省略時は全員 nil/0/[])。
    public struct MachineContext: Sendable {
        /// 実績レコードの machine と同じ語彙の識別子。不明なら nil(そのエントリは混合見積りのまま)
        public let entryMachines: [String?]
        /// そのエントリが払うディスパッチ固定費(実測。ローカルは 0)。台数で割らず
        /// 見込み終了時刻へそのまま足す(デバイスが走り出す前の壁時計)。
        /// **durations と同じ単位(ms)であること** —— 実績ゼロで見積りが単位重みへ退化する
        /// 呼び出しは machineContext(_:ifHistoryExists:) が offsets だけ 0 化して届ける
        /// (単位重み(1.0)と ms が同じ比較に混ざると offset が支配して壊れるため)
        public let entryFixedOffsetsMs: [Double]
        /// LPTScheduler.machineDurations(from:) の出力
        public let machineDurations: [LPTScheduler.MachineDuration]
        /// 実績の無い機械向けの事前係数(無次元。呼び出し側がコア数比等から算出する)。
        /// **無次元なので単位重み(unknownDurationMs)とも ms 実績とも安全に混ざる**
        /// (entryFixedOffsetsMs と違い、実績ゼロのガードで潰す必要が無い)。
        /// nil(省略)は全員 1.0 = 従来どおり混合見積りをそのまま使う
        public let entryFallbackFactors: [Double]

        public init(entryMachines: [String?], entryFixedOffsetsMs: [Double],
                    machineDurations: [LPTScheduler.MachineDuration],
                    entryFallbackFactors: [Double]? = nil) {
            self.entryMachines = entryMachines
            self.entryFixedOffsetsMs = entryFixedOffsetsMs
            self.machineDurations = machineDurations
            self.entryFallbackFactors = entryFallbackFactors
                ?? [Double](repeating: 1.0, count: entryMachines.count)
        }
    }

    public enum FleetSplitError: Error, LocalizedError, Equatable {
        /// scenario の platform に適合するエントリが1つも無い
        case noFittingEntry(scenarioID: String, platform: String)

        public var errorDescription: String? {
            switch self {
            case .noFittingEntry(let scenarioID, let platform):
                return "no fleet entry can run platform \"\(platform)\" scenario \(scenarioID)"
                    + " (add a device for that platform to one of the fleet's entries,"
                    + " or move the scenario off this fleet)"
            }
        }
    }

    /// fleet のどのエントリも持たない platform を宣言したシナリオを、partition の前に外す
    /// (単機の run の PlatformApplicability と同じ判定を、fleet 全体の platform 和集合で掛ける)。
    /// 全エントリが空集合なら runPlatforms が空 = 全件 runnable のまま partition へ渡り、
    /// 設定ミスとして throw される(黙って全件スキップの緑にしない)
    public static func applicability(
        scenarios: [(id: String, platform: String?)], entryPlatforms: [Set<String>]
    ) -> PlatformApplicability.Partition<(id: String, platform: String?)> {
        PlatformApplicability.partition(scenarios, runPlatforms: runPlatforms(entryPlatforms: entryPlatforms)) {
            $0.platform
        }
    }

    /// fleet 全体が回す platform の和集合(スキップ理由文 PlatformApplicability.reason に渡す)
    public static func runPlatforms(entryPlatforms: [Set<String>]) -> Set<String> {
        entryPlatforms.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// LPT で貪欲に詰める。
    /// - scenarios: platform は "ios" / "android" / nil(どちらでも可)
    /// - durations: 実績の中央値(LPTScheduler.durations(from:) の出力をそのまま渡す)。
    ///   **そのエントリが回す platform の記録だけ**を見る(宣言があればその platform、
    ///   未宣言なら entryPlatforms)。その範囲に複数 platform の記録があれば大きい方を採る
    ///   —— platform 未指定のシナリオはどちらへ転んでも過小評価にならないよう安全側に倒す
    /// - entryPlatforms: fleet の実行対象エントリと同じ並び・同じ本数。空集合 = そのエントリは
    ///   どのシナリオも受けない(呼び出し側は空バケツを skip として扱う)
    /// - unknownDurationMs: 実績の無いシナリオの見積り(既定値の根拠は呼び出し側のコメントに書く)
    /// - entryCapacities: エントリの**同時実行本数**(= 割り当てるデバイス台数)。省略時は全員 1。
    ///   分ける相手が「1ホスト = 1プロファイル」なら台数差は割り当てに現れないが、
    ///   デバイス単位の host 混在(1つの実行プロファイルの中に複数ホストのデバイスが並ぶ形)では
    ///   **台数が違うホストへ同じ量を配ると台数の少ない側が終わらない**。総量ではなく
    ///   「見込み終了時刻 = 負荷合計 / 台数」で比べる。全員同じ値なら比較順序は変わらないので、
    ///   既定(全員 1)の割り当ては従来と1バイトも変わらない
    /// - machineContext: 機械ごとの速度差・ディスパッチ固定費を見積りへ反映する(リモート実行)。
    ///   **投入順(降順ソート)は machineContext の有無によらず混合見積りで決める**
    ///   (機械非依存 = 決定的。エントリごとに順序が割れない)。nil(既定)は従来と完全一致
    ///   (offsets 全 0・machine 全 nil と同じ経路を通る)。
    public static func partition(
        scenarios: [(id: String, platform: String?)],
        durations: [LPTScheduler.Duration],
        entryPlatforms: [Set<String>],
        unknownDurationMs: Double,
        entryCapacities: [Double]? = nil,
        machineContext: MachineContext? = nil
    ) throws -> [Bucket] {
        try plan(scenarios: scenarios, durations: durations, entryPlatforms: entryPlatforms,
                 unknownDurationMs: unknownDurationMs, entryCapacities: entryCapacities,
                 machineContext: machineContext).buckets
    }

    /// partition と同じ割り当てに、見積りの根拠(EstimateBasis)を添えて返す。
    /// **根拠は割り当てが決まらないと数えられない**(どのシナリオがどのエントリへ行ったかで
    /// 通る分岐が変わる)ので、後から作り直せる形にはしない。
    public static func plan(
        scenarios: [(id: String, platform: String?)],
        durations: [LPTScheduler.Duration],
        entryPlatforms: [Set<String>],
        unknownDurationMs: Double,
        entryCapacities: [Double]? = nil,
        machineContext: MachineContext? = nil
    ) throws -> (buckets: [Bucket], basis: [EstimateBasis]) {
        let capacities = entryCapacities ?? [Double](repeating: 1, count: entryPlatforms.count)
        precondition(capacities.count == entryPlatforms.count,
                     "entryCapacities must line up with entryPlatforms")
        let entryMachines = machineContext?.entryMachines
            ?? [String?](repeating: nil, count: entryPlatforms.count)
        let entryOffsets = machineContext?.entryFixedOffsetsMs
            ?? [Double](repeating: 0, count: entryPlatforms.count)
        let entryFallback = machineContext?.entryFallbackFactors
            ?? [Double](repeating: 1.0, count: entryPlatforms.count)
        precondition(entryMachines.count == entryPlatforms.count,
                     "machineContext.entryMachines must line up with entryPlatforms")
        precondition(entryOffsets.count == entryPlatforms.count,
                     "machineContext.entryFixedOffsetsMs must line up with entryPlatforms")
        precondition(entryFallback.count == entryPlatforms.count,
                     "machineContext.entryFallbackFactors must line up with entryPlatforms")

        // 実績の索引は platform を潰さずに持つ(潰すと「その機械が直近で回した platform」の値が
        // 別 platform の run へ混ざる。ファイル冒頭の項)
        let mixedByScenario = medianByPlatform(durations)
        let sameByMachine = machineContext.map { medianByPlatformAndMachine($0.machineDurations) } ?? [:]
        // 係数は「機械間の比」なので platform を跨いで集めてよい。ただし比の分子・分母は
        // **同じ platform** で取る(speedFactors の項)。scope は fleet 全体が回す platform の和集合
        let runScope = runPlatforms(entryPlatforms: entryPlatforms)
        let factors = machineContext.map {
            speedFactors(machineDurations: $0.machineDurations, durations: durations, scope: runScope)
        } ?? [:]

        /// そのエントリでそのシナリオが実際に走る platform。宣言があればそれ、
        /// 未宣言ならそのエントリが回せる platform のどれか(= entryPlatforms)
        func scope(_ scenario: (id: String, platform: String?), forEntry index: Int) -> Set<String> {
            if let platform = scenario.platform { return [platform] }
            return entryPlatforms[index]
        }

        /// 全機混合の見積り。**scope 内に実績が無ければ全 platform へ退化する**
        /// (その platform をまだ1度も回していないプロジェクトで実績を捨てないため)。
        /// 退化してもよいのは混合側だけ —— 同一機側で同じことをすると、他機が持っている
        /// 正しい platform の実績より、その機械の別 platform の実績が勝ってしまう
        func mixedMs(_ id: String, _ scope: Set<String>) -> (ms: Double, known: Bool) {
            guard let byPlatform = mixedByScenario[id], !byPlatform.isEmpty else {
                return (unknownDurationMs, false)
            }
            if let inScope = maxWithin(byPlatform, scope: scope) { return (inScope, true) }
            return (byPlatform.values.max() ?? unknownDurationMs, true)
        }

        // エントリ別見積り優先順: ①同一機・同一 platform の実績 ②実測速度係数(factors)
        // ③事前係数(entryFallbackFactors)。machine 不明(nil)でも fallback は使う ——
        // ハードウェアの事前係数はプローブ由来で、レコード由来の machine 名が無くても得られる
        func estimate(_ scenario: (id: String, platform: String?), forEntry index: Int)
            -> (ms: Double, source: EstimateSource) {
            let scope = scope(scenario, forEntry: index)
            if let machine = entryMachines[index],
               let ownMs = maxWithin(sameByMachine[machine]?[scenario.id], scope: scope) {
                return (ownMs, .ownHistory)
            }
            let coefficient = entryMachines[index].flatMap { factors[$0] } ?? entryFallback[index]
            let mixed = mixedMs(scenario.id, scope)
            return (mixed.ms * coefficient, mixed.known ? .scaled : .unknown)
        }

        // 見積り降順、同着は scenario ID 昇順(決定的)。machine 非依存の混合見積りで決める
        // (scope は fleet 全体の和集合 = エントリを跨いでも同じ値になる)
        let ordered = scenarios.sorted { lhs, rhs in
            let l = mixedMs(lhs.id, lhs.platform.map { [$0] } ?? runScope).ms
            let r = mixedMs(rhs.id, rhs.platform.map { [$0] } ?? runScope).ms
            if l != r { return l > r }
            return lhs.id < rhs.id
        }

        var scenarioIDs = [[String]](repeating: [], count: entryPlatforms.count)
        var totals = [Double](repeating: 0, count: entryPlatforms.count)
        var sources = [[EstimateSource]](repeating: [], count: entryPlatforms.count)

        for scenario in ordered {
            let fitting = entryPlatforms.indices.filter { index in
                guard let platform = scenario.platform else { return !entryPlatforms[index].isEmpty }
                return entryPlatforms[index].contains(platform)
            }
            // 見込み終了時刻(固定費 + 負荷合計 / 台数)が最小のエントリへ。同着は entryIndex 昇順(決定的)。
            // 固定費は台数で割らない(デバイスが走り出す前の壁時計はデバイス数と無関係)
            func finishIfAssigned(_ index: Int) -> Double {
                entryOffsets[index]
                    + (totals[index] + estimate(scenario, forEntry: index).ms) / max(capacities[index], 1)
            }
            guard let target = fitting.min(by: {
                (finishIfAssigned($0), $0) < (finishIfAssigned($1), $1)
            }) else {
                throw FleetSplitError.noFittingEntry(
                    scenarioID: scenario.id, platform: scenario.platform ?? "ios/android")
            }
            let assigned = estimate(scenario, forEntry: target)
            scenarioIDs[target].append(scenario.id)
            totals[target] += assigned.ms
            sources[target].append(assigned.source)
        }

        let buckets = entryPlatforms.indices.map {
            Bucket(entryIndex: $0, scenarioIDs: scenarioIDs[$0], estimatedMs: totals[$0])
        }
        let basis = entryPlatforms.indices.map { index -> EstimateBasis in
            let machine = entryMachines[index]
            let measured = machine.flatMap { factors[$0] }
            return EstimateBasis(
                entryIndex: index, machine: machine,
                ownHistory: sources[index].filter { $0 == .ownHistory }.count,
                scaled: sources[index].filter { $0 == .scaled }.count,
                unknown: sources[index].filter { $0 == .unknown }.count,
                coefficient: measured ?? entryFallback[index],
                coefficientSource: measured != nil ? .measured
                    : (entryFallback[index] == 1.0 ? .none : .hardware))
        }
        return (buckets, basis)
    }

    /// 1シナリオ1エントリぶんの見積りがどこから来たか(EstimateBasis の集計元)
    private enum EstimateSource { case ownHistory, scaled, unknown }

    /// 呼び出し側の共通ガード: **実績が1件も無いときは entryFixedOffsetsMs を全 0 にした
    /// context を返す**。
    ///
    /// ms の offset は単位重み(1.0)と混ぜると支配して壊れる —— 実績ゼロだと呼び出し側の
    /// unknownDuration は単位重みへ退化するが、entryFixedOffsetsMs は実測ミリ秒のままなので、
    /// 比較の中で offset が重みを支配して**facts を持つエントリへは数千本積むまで1本も行かず、
    /// 全シナリオが facts の無いエントリ(local)へ寄る**(単位の混在は黙って誤る。2026-08-18 の
    /// レビューで検出)。
    ///
    /// **entryFallbackFactors は無次元なので単位重みと安全に併用できる** —— コア数の事前係数は
    /// むしろ実績ゼロのときにこそ効かせたいので、machineDurations/entryFallbackFactors は保持し、
    /// offsets だけを 0 化する(context ごと落とすのをやめた理由)
    public static func machineContext(
        _ context: MachineContext, ifHistoryExists durations: [LPTScheduler.Duration]
    ) -> MachineContext {
        guard durations.isEmpty else { return context }
        return MachineContext(
            entryMachines: context.entryMachines,
            entryFixedOffsetsMs: [Double](repeating: 0, count: context.entryFixedOffsetsMs.count),
            machineDurations: context.machineDurations,
            entryFallbackFactors: context.entryFallbackFactors)
    }

    /// 速度係数(machine → 比の中央値)。**比の分子と分母は必ず同じ platform で取る** ——
    /// 「その機械の中央値 / 全機混合の中央値」を platform を潰して作ると、機械が直近で回した
    /// platform と混合側の最長 platform が食い違ったときに、速度差ではなく **platform 差**を
    /// 係数として掛けることになる。platform を揃えれば platform は比で相殺されるので、
    /// 係数を集めること自体は platform を跨いでよい(機械間の比は platform に依らない前提)。
    ///
    /// - scope: 今回の run が回す platform。**まず scope 内の比だけで作り、1本も無い machine は
    ///   全 platform の比へ退化する**(その platform をまだ回していない機械でも係数は欲しい)。
    ///   空集合 / 省略は最初から全 platform。
    ///
    /// 共通観測が1本も無い machine は載らない(呼び出し側は `?? 事前係数` で扱う)。分母は
    /// unknownDurationMs ではなく durations の実績中央値だけを使う(実績ゼロのシナリオで係数を作らない)。
    public static func speedFactors(machineDurations: [LPTScheduler.MachineDuration],
                                    durations: [LPTScheduler.Duration],
                                    scope: Set<String> = []) -> [String: Double] {
        var mixed: [PlatformKey: Double] = [:]
        for duration in durations {
            let key = PlatformKey(scenarioID: duration.scenarioID, platform: duration.platform)
            mixed[key] = max(mixed[key] ?? 0, duration.medianMs)
        }
        var inScope: [String: [Double]] = [:]
        var anyPlatform: [String: [Double]] = [:]
        for duration in machineDurations {
            let key = PlatformKey(scenarioID: duration.scenarioID, platform: duration.platform)
            guard let mixedMs = mixed[key], mixedMs > 0 else { continue }
            let ratio = duration.medianMs / mixedMs
            anyPlatform[duration.machine, default: []].append(ratio)
            if scope.contains(duration.platform) { inScope[duration.machine, default: []].append(ratio) }
        }
        var factors: [String: Double] = [:]
        for (machine, ratios) in anyPlatform {
            let chosen = inScope[machine] ?? ratios
            guard !chosen.isEmpty else { continue }
            factors[machine] = median(of: chosen)
        }
        return factors
    }

    private struct PlatformKey: Hashable {
        let scenarioID: String
        let platform: String
    }

    /// scope 内で最大の中央値。**scope に1件も無ければ nil**(呼び出し側が退化するかどうかを
    /// 決める。同一機の実績で勝手に退化すると platform を跨いだ見積りが復活する)。
    /// scope が空集合なら platform を絞らない
    private static func maxWithin(_ byPlatform: [String: Double]?, scope: Set<String>) -> Double? {
        guard let byPlatform, !byPlatform.isEmpty else { return nil }
        guard !scope.isEmpty else { return byPlatform.values.max() }
        return byPlatform.filter { scope.contains($0.key) }.values.max()
    }

    /// scenarioID → platform → 中央値(platform を潰さない索引)
    private static func medianByPlatform(
        _ durations: [LPTScheduler.Duration]
    ) -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for duration in durations {
            let existing = result[duration.scenarioID]?[duration.platform] ?? 0
            result[duration.scenarioID, default: [:]][duration.platform] =
                max(existing, duration.medianMs)
        }
        return result
    }

    /// machine → scenarioID → platform → 中央値
    private static func medianByPlatformAndMachine(
        _ machineDurations: [LPTScheduler.MachineDuration]
    ) -> [String: [String: [String: Double]]] {
        var result: [String: [String: [String: Double]]] = [:]
        for duration in machineDurations {
            let existing = result[duration.machine]?[duration.scenarioID]?[duration.platform] ?? 0
            result[duration.machine, default: [:]][duration.scenarioID, default: [:]][duration.platform] =
                max(existing, duration.medianMs)
        }
        return result
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
