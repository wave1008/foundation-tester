// FM の常駐プロセス(`fleetest api fm-serve`)の本体。**画像を伴う FM の呼び出しはこのプロセスだけが撃つ**
// (なぜかは Sources/FTCore/FMServe.swift 冒頭)。通信・起動はそちら、受け付けループは FTCore の `FramedUnixSocket.serve`。
//
// 守る規律:
// ① **載せたままにする暖機(keep-warm)は実際の生成**: 最後の FM の利用から `keepWarmIntervalSeconds` 経つごとに、小さな画像の
//    転写を1回撃つ(`keepAlive`。前の1回が終わるまで次は撃たない)。**`prewarm` だけでは足りない** —— prewarm が載せたままにするのは
//    3B の本体と画像エンコーダだけで、**安全判定のモデル(instruct_300m.safety)は生成のたびに読まれ、約 5 秒で降ろされる**。
//    FM の死はその載せ直しで起きた(実測6回すべて。docs/maintainer-notes.md §81)。生成を休まず撃ち続けた形はデバイス実行の横でも
//    死ななかった。予備のセッション(`spare`)の `prewarm` は本番の転写の prefill のために残す
// ② **転写は予備のセッションを取り出して使い、実要求が終わった合間に予備を置き直す**(使ったセッションは捨てる)
// ③ **FMHealth・FMUsageLedger・FMBreaker に記録しない** —— 記録は要求した側(シナリオ・プローブ)が自分の所要で行う。
//    ここで記録すると run の結果 JSON(シナリオのプロセスの集計)と食い違い、プローブの「実仕事ではない」も崩れる
// ④ **セッションに `model:` を渡さない**(オンデバイス固定。PCC は禁止。FTCore/FMCallAdmission.swift 冒頭)
// ⑤ 期限: 1 要求は `FMServeWire.requestDeadlineSeconds` で打ち切って `failed` を返す(戻らない respond は放置)

import CoreGraphics
import Foundation
import FoundationModels
import FTCore
import ImageIO
import Synchronization

public enum FMServeServer {
    /// 暖機の間隔[秒]。最後の FM の利用(暖機を含む)が終わってからこれだけ空いたら次を撃つ。**根拠**: OS は最後の利用から
    /// 約 4〜5.5 秒で FM の部品を ANE から降ろす(M2Ultra の実測 4 回: 4 秒・5 秒・5.3 秒・5.4 秒で `Unloading asset`)。
    /// **数えるのは部品ごと** —— 画像エンコーダは1回の呼び出しの初めにしか使われないので、その部品の空きは「呼び出しの残り + 間隔」になる。
    /// 2.5 秒にしていたとき、1回が遅い M1Ultra では周期が 6〜9 秒に伸びた回に降ろされ、載せ直しの1回で FM が死んだ(M2Ultra は
    /// 1回が速く降ろしは 0 回だった)。1 秒 = M2Ultra で死ななかった「約 1 秒おきに撃ち続ける」形(528 回)と同じ間隔。
    /// **尽きたとき**(撃てなかった間隔が空いた): 降ろされ、次の呼び出しで載せ直す(= このプロセスが防ぎたい瞬間)。
    /// 遅い回は `slowKeepAliveSeconds` を超えたら fm-serve のログへ1行出す(機械ごとの1回の所要を後から切り分ける)
    static let keepWarmIntervalSeconds: Double = 1.0

    /// 暖機1回の所要がこれを超えたらログへ出す[秒]。OS が降ろすまでの実測の下限(4 秒)= これより遅い回は、その間に
    /// 呼び出しの初めに使った部品が降ろされうる
    static let slowKeepAliveSeconds: Double = 4

    /// 直近 `keepWarmWindow` 回の暖機のうち、遅い回(`slowKeepAliveSeconds` 超え)が `keepWarmGiveUpSlowCalls` 回以上なら、
    /// このプロセスの間は暖機をやめる。**理由**: この機械の ANE には全部品が収まらず、暖機は載せたままにできないまま積み下ろしを
    /// 撃ち続けるだけになっている(M1mini・メモリ 8GB: 60 秒で降ろし 129 回・載せ直し 82 回・遅い回はおよそ半分)。**「続いた回数」で
    /// 見ない** —— M1mini は速い回が間に挟まり、5 回続く条件は一度も満たさなかった。**根拠**: 遅い回は M2Ultra で 0・M1Max で数分に
    /// 1 回・M1Ultra は E2EX 一式の負荷の下で約 30 分に 6 回(続いても 2 回)= 20 回中 6 回(30%)なら M1mini だけを分けられる。
    /// **尽きたとき**: 暖機をやめるだけ(FM の呼び出しは頼まれたときだけ = 常駐プロセスを入れる前と同じ。1 行ログへ出す)
    static let keepWarmWindow = 20
    static let keepWarmGiveUpSlowCalls = 6

    /// 暖機を続けるか(純粋関数)。`recent` は直近の暖機が遅かったか(古い順・最大 `keepWarmWindow` 件)。
    /// 窓が埋まるまでは判断しない(起動直後の載せ込みの遅さで決めない)
    static func keepWarmStillUseful(recent: [Bool]) -> Bool {
        guard recent.count >= keepWarmWindow else { return true }
        return recent.suffix(keepWarmWindow).filter { $0 }.count < keepWarmGiveUpSlowCalls
    }

    /// 受け付けループが暖機・寿命を判断する刻み[ms]。暖機の間隔より細かければよい
    static let tickMilliseconds: Int32 = 500

    /// 転写の出力上限(`OcclusionVerifier.transcriptResponseTokens` の doc)・死活の確かめの上限
    static let probeTextTokens = 8
    static let probeVisionTokens = 16

    /// 予備のセッション(テキストの可視性検証の instructions で暖めたもの。規律①②)
    static let spare = PreloadSlot<LanguageModelSession>()

    private struct Clock: Sendable {
        var lastFMUse = Date.distantPast
        var lastRequest = Date()
    }
    private static let clock = Mutex(Clock())
    private static let stopRequested = Mutex(false)
    private static let activity = FMServeActivity()
    private static let spareNeedsWarm = Mutex(false)

    private static func requestStop() { stopRequested.withLock { $0 = true } }

    /// 終わるまで戻らない。戻り値 = 終了コード
    public static func run(socketPath: String, shouldStop: @escaping @Sendable () -> Bool,
                           log: @escaping @Sendable (String) -> Void) -> Int32 {
        // 実体のパスを名乗る(リンク経由のパスだと、リンクの作り直しの瞬間に呼び手が印を読めない = ExecutablePath)
        let executable = ExecutablePath.current?.path ?? ""
        let stamp = FMServeWire.buildStamp(executable: executable)
        log("serving \(socketPath) (protocol \(FMServeWire.protocolVersion), \(executable) \(stamp))")
        warmSpare()
        let code = FramedUnixSocket.serve(
            socketPath: socketPath, requestDeadlineSeconds: FMServeWire.clientDeadlineSeconds,
            tickMilliseconds: tickMilliseconds,
            shouldStop: { shouldStop() || stopRequested.withLock { $0 } },
            onTick: { tick(log: log) },
            handle: { payload in await handle(payload, executable: executable, stamp: stamp, log: log) },
            log: log)
        log("stopped (exit \(code))")
        return code
    }

    /// 暖機と寿命の判断(受け付けループの合間)
    static func tick(log: @escaping @Sendable (String) -> Void, now: Date = Date()) {
        let state = clock.withLock { $0 }
        if now.timeIntervalSince(state.lastRequest) > FMServeWire.idleExitSeconds {
            log("no request for \(Int(FMServeWire.idleExitSeconds))s; exiting")
            stopRequested.withLock { $0 = true }
            return
        }
        // FM を使っているあいだ生きているのはこのプロセス = 死の直前のメモリの推移を確実に持てる。
        // 取得は専用キューで即戻る(この周期の中で `top` を待たない)
        FMHostMemory.sampleIfDue(now: now)
        let knownDead = FMLiveness.isKnownDead(.vision)
        let generate = keepWarmStillUseful(recent: recentKeepAlives.withLock { $0 })
            && shouldWarm(lastFMUse: state.lastFMUse, now: now, knownDead: knownDead)
        guard !knownDead, generate || spareNeedsWarm.withLock({ $0 }) else { return }
        let gap = state.lastFMUse == .distantPast ? 0 : now.timeIntervalSince(state.lastFMUse)
        activity.startWarm(deadlineSeconds: FMServeWire.requestDeadlineSeconds, log: log,
                           onCompletion: { took in
            clock.withLock { $0.lastFMUse = Date() }
            if generate {
                if took > slowKeepAliveSeconds || gap > slowKeepAliveSeconds {
                    log(String(format: "slow keep-warm: the call took %.1fs after a %.1fs gap since the last FM use; %@",
                               took, gap, activity.snapshot.description))
                }
                let recent = recentKeepAlives.withLock { history -> [Bool] in
                    history.append(took > slowKeepAliveSeconds)
                    if history.count > keepWarmWindow { history.removeFirst(history.count - keepWarmWindow) }
                    return history
                }
                // やめた後は暖機を撃たない = この行は1度しか出ない
                if !keepWarmStillUseful(recent: recent) {
                    log("keep-warm stopped: \(recent.filter { $0 }.count) of the last \(recent.count) calls took over"
                        + " \(Int(slowKeepAliveSeconds))s, so this machine cannot keep the model loaded;"
                        + " FM is now loaded only when a request comes")
                }
            }
        }, operation: {
            if spareNeedsWarm.withLock({ needed -> Bool in
                let result = needed
                needed = false
                return result
            }) { prewarmSpare() }
            if generate { try await keepAlive() }
        })
    }

    private static let recentKeepAlives = Mutex<[Bool]>([])

    /// 小さな画像の転写を1回(答えは見ない・記録しない = 規律③)。本番の転写と同じ instructions・prompt で撃ち、同じ部品
    /// (画像トークナイザ・mm_guard・安全判定)を載せたままにする。**毎回新しいセッション**(1 つのセッションで生成を繰り返すと
    /// 会話履歴が伸びて文脈長の上限に当たる)。期限は実呼び出しと同じ
    static func keepAlive() async throws {
        guard #available(macOS 27, *) else { return }
        let session = LanguageModelSession(instructions: OcclusionVerifier.instructions)
        _ = try await session.respond(
            generating: DrawnTextTranscript.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: keepAliveTokens)
        ) {
            OcclusionVerifier.prompt
            Attachment(FMLoadGenerator.probeImage)
        }
    }

    /// 暖機の生成の出力上限。答えは使わないので最小(探り画像は単色 = 転写は空になる)
    static let keepAliveTokens = 8

    /// 暖機を撃つか(純粋関数)。死んでいると分かっている FM には撃たない(載せ直しの失敗を重ねない)
    static func shouldWarm(lastFMUse: Date, now: Date, knownDead: Bool) -> Bool {
        !knownDead && now.timeIntervalSince(lastFMUse) >= keepWarmIntervalSeconds
    }

    static func warmSpare() {
        spareNeedsWarm.withLock { $0 = true }
    }

    private static func prewarmSpare() {
        // prewarm は非同期の先読みを始める API。門で守れるのは呼び出す瞬間までで、完了を待つ API は無い。
        spare.preload(instructions: OcclusionVerifier.instructions,
                      make: { LanguageModelSession(instructions: $0) },
                      warm: { session in
                          if #available(macOS 27, *) {
                              // 画像の部品(画像エンコーダ)まで載せる。文字だけの prewarm では画像の部品が降ろされた(実測)
                              session.prewarm(promptPrefix: Prompt {
                                  OcclusionVerifier.prompt
                                  Attachment(FMLoadGenerator.probeImage)
                              })
                          } else {
                              session.prewarm()
                          }
                      })
    }

    // MARK: - 要求の処理

    enum Outcome: Sendable {
        case answered(text: String?, pass: Bool?, reason: String?)
        case failed(String)
        case refused(String)
    }

    static func handle(
        _ payload: Data, executable: String, stamp: String,
        activity: FMServeActivity = FMServeServer.activity,
        deadlineSeconds: Double = FMServeWire.requestDeadlineSeconds,
        log: @escaping @Sendable (String) -> Void = { _ in },
        requestStop: @escaping @Sendable () -> Void = FMServeServer.requestStop,
        operation: @escaping @Sendable (FMServeWire.Request) async throws -> Outcome = perform
    ) async -> Data? {
        func reply(_ status: FMServeWire.Response.Status, text: String? = nil, pass: Bool? = nil,
                   reason: String? = nil, error: String? = nil, retryCount: Int = 0) -> Data? {
            try? JSONEncoder().encode(FMServeWire.Response(status: status, text: text, pass: pass, reason: reason,
                                                           error: error, retryCount: retryCount,
                                                           executable: executable, buildStamp: stamp))
        }
        func identity(_ status: FMServeWire.Status) -> Data? {
            try? JSONEncoder().encode(FMServeWire.Identity(status: status, executable: executable, buildStamp: stamp))
        }
        guard let request = try? JSONDecoder().decode(FMServeWire.Request.self, from: payload) else {
            guard let retirement = try? JSONDecoder().decode(FMServeWire.RetirementRequest.self, from: payload) else {
                return reply(.failed, error: "the request could not be decoded")
            }
            let current = FMServeWire.Identity(status: .ok, executable: executable, buildStamp: stamp)
            let outcome: FMServeWire.RetirementResponse.Outcome
            if retirement.controlVersion != FMServeWire.retirementProtocolVersion {
                outcome = .unsupported
            } else if retirement.target.serverVersion != current.serverVersion
                        || retirement.target.executable != current.executable
                        || retirement.target.buildStamp != current.buildStamp {
                outcome = .identityMismatch
            } else if retirement.replacementVersion < current.serverVersion {
                outcome = .newerServer
            } else if activity.tryRetireIfIdle() {
                outcome = .retiring
                requestStop()
            } else {
                outcome = .busy
            }
            return try? JSONEncoder().encode(FMServeWire.RetirementResponse(identity: current, outcome: outcome))
        }
        guard request.version == FMServeWire.protocolVersion else {
            if request.kind == .status || request.kind == .shutdown { return identity(.versionMismatch) }
            return reply(.versionMismatch, error: "protocol \(request.version) != \(FMServeWire.protocolVersion)")
        }
        switch request.kind {
        case .status:
            return identity(.ok)
        case .shutdown:
            // 旧呼び手は相手自身の版を送るため、ここでは新版を止める権限を確認できない。
            return identity(.failed)
        case .transcribe, .screen, .probe:
            break
        }
        clock.withLock { $0.lastRequest = Date() }
        let context = FMServeActivity.RequestContext(deadlineSeconds: deadlineSeconds)
        let outcome = await activity.request(context: context, log: log,
                                             onCompletion: { clock.withLock { $0.lastFMUse = Date() } }) { context in
            await requestWithRetry(request, context: context, activity: activity, log: log, operation: operation)
        }
        let retryCount = context.closeResponse()
        switch outcome {
        case .answered(let text, let pass, let reason)?:
            return reply(.ok, text: text, pass: pass, reason: reason, retryCount: retryCount)
        case .failed(let description)?:
            return reply(.failed, error: description, retryCount: retryCount)
        case .refused(let description)?:
            return reply(.refused, error: description, retryCount: retryCount)
        case nil:
            guard !context.wasRejectedForRetirement else { return nil }
            return reply(.failed, error: "no answer within \(Int(deadlineSeconds))s", retryCount: retryCount)
        }
    }

    private static func perform(_ request: FMServeWire.Request) async throws -> Outcome {
        switch request.kind {
        case .transcribe:
            guard #available(macOS 27, *) else { return .failed(FMVisionSupport.requirement) }
            guard let image = image(request.png) else { return .failed("the request has no readable PNG") }
            return .answered(text: try await transcribe(image), pass: nil, reason: nil)
        case .screen:
            guard #available(macOS 27, *) else { return .failed(FMVisionSupport.requirement) }
            guard let image = image(request.png), let expected = request.expected else {
                return .failed("the request has no readable PNG or expected state")
            }
            let verdict = try await screen(image, expected: expected)
            return .answered(text: nil, pass: verdict.pass, reason: verdict.reason)
        case .probe:
            try await probe(request.path ?? .vision)
            return .answered(text: nil, pass: nil, reason: nil)
        case .status, .shutdown:
            return .answered(text: nil, pass: nil, reason: nil)
        }
    }

    static func image(_ png: Data?) -> CGImage? {
        guard let png, let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// テキストの可視性検証の転写。**期待文字列は受け取らない**(prompt は定数。OcclusionVerifier 冒頭)
    @available(macOS 27, *)
    static func transcribe(_ image: CGImage) async throws -> String {
        let session = spare.take(matching: OcclusionVerifier.instructions)
            ?? LanguageModelSession(instructions: OcclusionVerifier.instructions)
        // 予備の置き直しを予約する。実要求どうしは並行に走るので、この defer から直接 prewarm を撃たない。
        defer { warmSpare() }
        return try await session.respond(
            generating: DrawnTextTranscript.self,
            options: GenerationOptions(samplingMode: .greedy,
                                       maximumResponseTokens: OcclusionVerifier.transcriptResponseTokens)
        ) {
            OcclusionVerifier.prompt
            Attachment(image)
        }.content.text
    }

    static let screenInstructions = """
    You verify screens for UI tests. Look at the screenshot and judge strictly
    whether it matches the expected state.
    """

    @available(macOS 27, *)
    static func screen(_ image: CGImage, expected: String) async throws -> (pass: Bool, reason: String) {
        let session = LanguageModelSession(instructions: screenInstructions)
        let verdict = try await session.respond(
            generating: ScreenVerdict.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200)
        ) {
            "Expected screen state: \(expected)\nDecide whether the screenshot below matches this state."
            Attachment(image)
        }.content
        return (verdict.pass, String(verdict.reason.prefix(200)))
    }

    /// 死活の確かめの実呼び出し 1 回(答えの中身は見ない)
    static func probe(_ path: FMLiveness.Path) async throws {
        switch path {
        case .text:
            _ = try await LanguageModelSession().respond(
                to: "Answer with just OK.",
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: probeTextTokens))
        case .vision:
            guard #available(macOS 27, *) else { throw FMServeProbeError.visionUnsupported }
            _ = try await LanguageModelSession().respond(
                generating: FMLoadGenerator.LoadVisionVerdict.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: probeVisionTokens)
            ) {
                "Is this image a single solid color?"
                Attachment(FMLoadGenerator.probeImage)
            }
        }
    }
}

enum FMServeProbeError: Error, CustomStringConvertible {
    case visionUnsupported
    var description: String { FMVisionSupport.requirement }
}
