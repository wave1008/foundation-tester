// BlankWorkerTriage.swift
// run の**開始前**に「画面だけ死んでいるデバイス」を弾く。
//
// Android には同じものが既にある(`ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers`。
// あちらは sleep/wake と guest reboot で**修復**まで行う)。**iOS には無かった**ため、
// 2026-08-05 に E2E-CMP の `-06` が「画面は真っ黒・a11y ツリーは健全・タップだけ届かない」
// 状態になったとき、9/9 の失敗が**無警告でテストの失敗として記録された**(docs/verification.md
// 「iOS シミュレータも『画面だけ死ぬ』」)。失敗して初めて分かるのでは遅い。
//
// **修復そのものはここに持たない**(iOS で確認できている回復手段は `simctl shutdown`→`boot`
// だけで、ブリッジごと作り直しになる)。代わりに**回復を呼び出し側から注入できる**ようにしてある
// (`recover:`)。ブリッジを張り直せるのは供給を持っている側(ProfileRunner)だけなので、
// 判定はここ・回復はあちら、と役割を割る。
//
// **レーンに凍結機を残さない**(2026-08-09 のユーザー決定): 検出したら回復を試み、
// 回復できたものはレーンに戻し、**どうしても回復できないものだけ外す**。
// 回復を注入しない呼び出し(`recover` 省略)は従来どおり「弾いて直し方を出す」だけ。

import Foundation

public enum BlankWorkerTriage {

    /// 判定結果。excluded はワーカー label(呼び出し側がログ・監査に使う)
    public struct Result {
        public let workers: [RunWorker]
        public let excluded: [String]
        public init(workers: [RunWorker], excluded: [String]) {
            self.workers = workers
            self.excluded = excluded
        }
    }

    /// blank を確定させるサンプル数と間隔。**単発のフレームでは決めない**
    /// (アプリ起動直後の白/黒フレームを凍結と誤断する)。Android 側の run 前トリアージと同じ規約
    public static let samples = 2
    public static let intervalMs = 1_500

    /// **どのワーカーを弾くかの判定だけ**を切り出した純粋ロジック(デバイス不要 = 単体テストで固める)。
    /// `blankByLabel` は「そのワーカーが恒常 blank か」。元の順序を保ったまま除外する
    public static func exclude(_ workers: [RunWorker],
                               blankByLabel: [String: Bool]) -> Result {
        let excluded = workers.map(\.label).filter { blankByLabel[$0] == true }
        guard !excluded.isEmpty else { return Result(workers: workers, excluded: []) }
        let kept = workers.filter { blankByLabel[$0.label] != true }
        return Result(workers: kept, excluded: excluded)
    }

    /// 対象にするワーカーか。**iOS の仮想デバイスだけ**:
    ///   - Android は自前のトリアージ(修復つき)が既にある = 二重に撃たない
    ///   - 実機は「画面が消灯しているだけ」を凍結と誤断する(Android 側と同じ理由)
    public static func isCandidate(_ worker: RunWorker) -> Bool {
        worker.platform == "ios" && !worker.connection.physical
    }

    /// 恒常 blank かを判定する(`samples` 回続けて一様フレームなら blank)。
    /// **撮れなかったフレームは「健全」に倒す**(誤って健全機を弾かない安全側。Android の
    /// probeBlank と同じ方針)。screenshot はテストから差し替えられるよう引数で受ける
    public static func isPersistentlyBlank(
        screenshot: () async -> Data?,
        samples: Int = samples,
        sleep: (Int) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
    ) async -> Bool {
        for index in 0..<max(1, samples) {
            if index > 0 { await sleep(intervalMs) }
            guard let shot = await screenshot(),
                  BlankFrameDetector.isUniformBlank(pngData: shot) else { return false }
        }
        return true
    }

    /// 共有ストア・注入と揃えるためのデバイスキー(iOS=UDID / Android=serial)。
    /// `RunLease` / `DeviceFrozenStore` と**同じキー体系**でなければモニターと突き合わない
    public static func deviceKey(_ worker: RunWorker) -> String? {
        worker.connection.udid ?? worker.connection.serial
    }

    /// 1台ぶんの判定。**根拠を返す**ので、呼び出し側は真偽値を自前で持たない。
    /// 注入(陽性対照)はスクショより先に見る —— 実デバイスを凍らせずに検知経路を通すための口で、
    /// ここを通さないと run 側とモニター側で注入の効き方がズレる
    /// しきい値の定義元は `FrozenVerdict`(run とモニターで1つ)。ここは別名
    public static var displayIdleFrozenThreshold: Double { FrozenVerdict.displayIdleFrozenThreshold }

    public static func observedVerdict(
        key: String?,
        screenshot: () async -> Data?,
        displayIdleSeconds: Double? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> FrozenVerdict {
        if FrozenInjection.isInjected(key: key, environment: environment) {
            return FrozenVerdict([.injected])
        }
        // **判定規則はモニターと共通**(FrozenVerdict.observe)。一様でも拍動が生きていれば
        // 凍結としない = アプリの初回描画待ちでフリートを再起動しない
        return FrozenVerdict.observe(uniformBlank: await isPersistentlyBlank(screenshot: screenshot),
                                     displayIdleSeconds: displayIdleSeconds)
    }

    /// 凍結したワーカーの label と根拠(並列判定)。健全機は1サンプルで即返るので、
    /// 正常時の固定費はスクショ1枚ぶん
    public static func frozenVerdicts(
        _ workers: [RunWorker],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: (@Sendable (String) -> Void)? = nil
    ) async -> [String: FrozenVerdict] {
        let candidates = workers.filter(isCandidate)
        guard !candidates.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, FrozenVerdict).self,
                                   returning: [String: FrozenVerdict].self) { group in
            for worker in candidates {
                group.addTask {
                    // 拍動の申告はブリッジの /status から採る(計器を持たない版は nil = 根拠にしない)
                    let displayIdle = try? await worker.driver.status().displayIdleSeconds
                    let verdict = await observedVerdict(key: deviceKey(worker),
                                                        screenshot: { try? await worker.driver.screenshot() },
                                                        displayIdleSeconds: displayIdle ?? nil,
                                                        environment: environment)
                    // **見送ったことを残す**(2026-08-11 の実測): 一様なのに拍動が生きている機は
                    // 凍結として扱わない。これを黙って捨てると「なぜ回復しなかったのか」が
                    // 追えなくなる(逆に、本物の凍結を取り逃がしたときの手掛かりにもなる)
                    if !verdict.isFrozen, let idle = displayIdle ?? nil,
                       idle <= displayIdleFrozenThreshold {
                        log?("ℹ️ \(worker.label): the frame is uniform but the display is still"
                            + " advancing (idle \(String(format: "%.2f", idle))s)"
                            + " — not treating it as frozen (the app is probably still painting)")
                    }
                    return (worker.label, verdict)
                }
            }
            // **確定していない根拠も返す**(呼び出し側が警告として出す)。
            // ここで isFrozen だけに絞ると、警告から始める運用そのものができなくなる
            var found: [String: FrozenVerdict] = [:]
            for await (label, verdict) in group where verdict.isSuspected || verdict.isFrozen {
                found[label] = verdict
            }
            return found
        }
    }

    /// **確定した**凍結ワーカーの label 一覧(疑いだけの機は含めない)
    public static func frozenLabels(_ workers: [RunWorker]) async -> [String] {
        await frozenVerdicts(workers).filter { $0.value.isFrozen }.map(\.key)
    }

    /// 回復を試みる回数の上限。**2回**: 1回で戻らない個体はもう1回でも戻らないことが多く、
    /// run の立ち上がりを何分も伸ばすほうが害になる(戻らなければ外して先へ進む)
    public static let recoveryAttempts = 2

    /// run 開始前のトリアージ本体。
    ///
    /// `recover` を渡すと、凍結を見つけたときに**回復を試み、戻ったものはレーンに残す**。
    /// 戻り値は回復後に作り直したワーカー一覧で、呼び出し側はそれを使う。回復できなかった
    /// ものだけを外すので、**レーンに凍結機が残らない**。省略時は従来どおり弾くだけ。
    ///
    /// `recover` の契約: 渡された label 群のデバイスを回復し、**ブリッジを張り直した**
    /// ワーカー一覧を返す。回復手段が無い/失敗したら nil(即座に除外へ進む)。
    ///
    /// **第2引数で「今の」ワーカー一覧を渡す**のが要点(2026-08-11 の実害)。回復すると
    /// ブリッジを張り直すのでポート = label が変わる。呼び出し側が最初の一覧を捕まえたままだと、
    /// 2回目の試行で渡される新しい label を引けず udid が取れない
    /// (`frozen devices have no iOS simulator udid` で回復が必ず失敗する)
    /// 判定を共有ストアへ反映する(`stateDir` 省略時は何もしない)。
    /// **自分が書いた分を消してから公表し直す**ので、回復した機の消し込みが自動で揃う
    /// (「回復したら clear する」を別に書くと必ず片方だけ直る)。
    private static func syncStore(_ verdicts: [String: FrozenVerdict],
                                  of workers: [RunWorker], stateDir: URL?) {
        guard let stateDir else { return }
        DeviceFrozenStore.clearAll(stateDir: stateDir)
        var keysByLabel: [String: String] = [:]
        for worker in workers { keysByLabel[worker.label] = deviceKey(worker) }
        for (label, verdict) in verdicts {
            guard let key = keysByLabel[label] else { continue }
            DeviceFrozenStore.publish(stateDir: stateDir, key: key, verdict: verdict)
        }
    }

    /// ログ用。根拠が既定(一様 blank)だけのときは従来どおり label だけを並べ、
    /// それ以外(注入・拍動)が混じるときだけ根拠を添える
    private static func describe(_ verdicts: [String: FrozenVerdict]) -> String {
        verdicts.keys.sorted().map { label in
            let verdict = verdicts[label] ?? .healthy
            guard verdict.evidence != [.uniformBlank] else { return label }
            return "\(label) [\(verdict.summary)]"
        }.joined(separator: ", ")
    }

    public static func excludeBlankScreenWorkers(
        _ workers: [RunWorker],
        recover: (@Sendable ([String], [RunWorker]) async -> [RunWorker]?)? = nil,
        stateDir: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping @Sendable (String) -> Void
    ) async -> Result {
        var current = workers
        var verdicts = await frozenVerdicts(current, environment: environment, log: log)
        // **判定した時点で公表する**(回復は数分かかりうるので、終わってから配るとモニターは
        // その間ずっと「異常なし」を出す = 見えるようにした意味が無い)
        syncStore(verdicts, of: current, stateDir: stateDir)
        // **確定していない根拠は警告だけ**(新しい検知は拒否でなく警告から始める規律)
        for (label, verdict) in verdicts.filter({ $0.value.isSuspected }).sorted(by: { $0.key < $1.key }) {
            log("⚠️ \(label): the display may have stopped advancing [\(verdict.summary)]"
                + " — not treating it as frozen (this signal is not confirmed yet)")
        }
        // **注入(陽性対照)は公表だけで、回復も除外もしない** —— 実体は健全なので
        // simctl shutdown/boot を撃つと対照実験のたびにフリートを再起動することになる
        var blankLabels = verdicts
            .filter { $0.value.isFrozen && !$0.value.isInjectedOnly }.keys.sorted()
        guard !blankLabels.isEmpty else { return Result(workers: current, excluded: []) }

        if let recover {
            for attempt in 1...recoveryAttempts {
                log("⚠️ \(blankLabels.count) device(s) have a frozen screen"
                    + " (\(describe(verdicts.filter { $0.value.isFrozen && !$0.value.isInjectedOnly })))"
                    + " — recovering before the run starts"
                    + " (attempt \(attempt)/\(recoveryAttempts))")
                guard let rebuilt = await recover(blankLabels, current) else { break }
                current = rebuilt
                verdicts = await frozenVerdicts(current, environment: environment, log: log)
                syncStore(verdicts, of: current, stateDir: stateDir)
                blankLabels = verdicts
                    .filter { $0.value.isFrozen && !$0.value.isInjectedOnly }.keys.sorted()
                if blankLabels.isEmpty {
                    log("✅ every frozen device recovered — starting with all lanes")
                    return Result(workers: current, excluded: [])
                }
            }
        }

        for label in blankLabels {
            // **直し方まで書く**。iOS には自動修復が無いので、ここで手順が出ないと
            // 「弾かれた」だけが残って次の run でも同じ個体が死んでいる
            log("⚠️ \(label): the screen is frozen (a11y still responds but nothing renders and taps"
                + " do not land) — could not recover it, so it is excluded from dispatch."
                + " Recover it with: xcrun simctl shutdown <udid> && xcrun simctl boot <udid>")
        }
        return exclude(current, blankByLabel: Dictionary(
            uniqueKeysWithValues: blankLabels.map { ($0, true) }))
    }
}
