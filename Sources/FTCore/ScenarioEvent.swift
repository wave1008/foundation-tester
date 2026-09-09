// ScenarioEvent.swift
// fleetest-scenarios(サブプロセス)とホスト(CLI/MCP)の間で交わす NDJSON イベントの DTO。
// Foundation 以外に依存しないこと(ホスト側の軽量パースを保つ)。
// kind: scenarioStarted / sceneStarted / step / sceneFinished / fixSuggestion / scenarioFinished / log / deviceFrozen / installRequest
// step は tap/exist 等 1 操作の結果(既存 StepResult と同語彙)。
// installRequest は installApp() の子→親 RPC 専用(ScenarioInstall.swift)。ScenarioHost.run が
// 横取りして stdin へ応答を書き、呼び出し側の emit へは渡さない — **fleetest api の NDJSON 契約には
// 現れない**(ProtocolVersion の対象外)。

import Foundation

public struct ScenarioEvent: Codable, Sendable {
    public var kind: String
    /// このイベントを処理したワーカーの識別子("<platform>:<デバイス論理名>"。
    /// fleetest api monitor の monitorDevices の id と同一規則)。--profile 指定時の並列実行
    /// (fleetest api run)でのみ設定、逐次実行では nil(エンコード時にキーごと省略)
    public var worker: String?
    /// シナリオ ID(クラス名.メソッド名)
    public var scenario: String?
    /// シナリオのタイトル(@Test の引数)
    public var title: String?
    public var scene: Int?
    public var sceneTitle: String?
    /// condition / action / expectation(CAE ブロック外は nil)
    public var section: String?
    /// ステップの通し番号(シナリオ内)
    public var index: Int?
    /// ステップの人間可読な説明
    public var description: String?
    /// passed / passedViaFallback / healed / failed / skipped
    public var status: String?
    /// 失敗理由・フォールバック内容・修正提案文など
    public var detail: String?
    /// コマンド呼び出し元のソース位置(修正提案用)
    public var file: String?
    public var line: Int?
    /// kind == fixSuggestion(強い提案)の旧セレクタ・新セレクタ(修復候補の確認 UI 向け)
    public var oldSelector: String?
    public var newSelector: String?
    /// scenarioFinished / sceneFinished 用
    public var passed: Bool?
    public var reportPath: String?
    /// kind == log(ユーザー print の混入行など)
    public var message: String?
    /// kind == step のステップ全体の所要時間(ミリ秒。計測は ContinuousClock)。
    /// 後発の追加フィールド: Optional なので Codable 合成が欠損キーを自動で nil にし
    /// (decodeIfPresent 相当)、旧クライアントとの互換を保つ
    public var durationMs: Int?
    /// durationMs の内訳: セレクタ解決のための snapshot 取得合計(ミリ秒)
    public var snapshotMs: Int?
    /// durationMs の内訳: driver 操作呼び出し(tap/type/press/swipe/screenshot)の合計(ミリ秒)
    public var actionMs: Int?
    /// durationMs の内訳: 固定 sleep・ポーリング待ちの合計(ミリ秒)
    public var waitMs: Int?
    /// **順番待ち**: このステップの async タスクを作ってから最初の1命令が走るまで(ミリ秒)。
    /// 協調スレッドプールが詰まると、ステップは1命令も実行しないまま壁時計だけが進む ——
    /// 締め切り(FTSync.commandTimeout)が妥当かを判断する材料(実測 2026-09-10: 20 秒超の
    /// ステップは snapshot/action/wait のどれにも計上されない時間が 99.7% を占めていた)
    public var scheduleDelayMs: Int?
    /// **このプロセスが実際に貰えた CPU 時間**(user+sys の増分。ミリ秒)。ホストが飽和していると
    /// 壁時計は進むのに CPU はほとんど増えない。**単独ではハングを検出できない**
    /// (I/O 待ちも CPU 0)ので、進捗の尺度と組み合わせて読む
    public var cpuMs: Int?
    /// **出力経路でブロックされた時間**(ミリ秒)。stdout/stderr は全書き手が1個のロックと
    /// blocking な write(2) を共有するので、読み手が詰まると協調スレッドプールごと止まり
    /// **全レーンが同時に固まる**(ConsoleOut の doc)。ここが durationMs の大半を占める
    /// ステップは、仕事をしていないのではなく**書けなくて進めなかった**
    public var ioBlockedMs: Int?
    /// kind == scenarioFinished。このシナリオの FM 呼び出し実測(回数・レイテンシ)。
    /// FM を使わなかったシナリオでは nil(キーごと省略)。FM はホスト全体で直列化するため、
    /// 並列実行では他レーンの待ちも含む値になる(FMHealth の doc 参照)
    public var fm: FMUsageRecord?
    /// kind == step。run を跨いで数える注記の機械可読コード(StepNote の rawValue)。
    /// 表示は description の括弧書きに含まれるが、**集計は必ずこちらを見る**
    /// (文言を変えた瞬間に集計が 0 件になるのを防ぐ。StepNote の doc 参照)。
    /// 後発の追加フィールドで Optional = 旧クライアント互換
    public var notes: [String]?
    /// kind == step。ステップの結果が確定した壁時計時刻(ISO8601+ミリ秒)。動画録画(record:true)の
    /// 再生位置ジャンプ用(録画の startedAt と突き合わせる)。failed 以外も付与されるが、
    /// 永続化(FailedStepRecord.at)は失敗ステップのみ
    public var at: String?
    /// kind == step。**DSL のコマンド名**(`tap` / `exist` / `textIs` …)。
    /// description から切り出さずに運ぶ —— 説明文は group の前置や注記の括弧書きが付くので、
    /// 文字列を割って数えると書式を変えた瞬間に静かに壊れる(notes と同じ理由)。
    /// 名前の集合は `CommandIndex`
    public var command: String?
    /// kind == step かつ status == failed。**どの経路で落ちたか**(`StepFailureKind` の rawValue)。
    /// 言えないときはキーごと省略 = 推測で埋めない
    public var failureKind: String?
    /// kind == installRequest。子→親 RPC の相関 id(ScenarioInstallControl が発番)
    public var requestID: Int?
    /// kind == installRequest。installApp() の明示引数(nil = 親が実行プロファイルの appPath を解決する)
    public var installPath: String?
    /// kind == step。[occlusion-guard] このステップが `occlusionFlip` の `visibilityGuardActive`
    /// 判定を通ったか(StepOutcome.guardEntered)。action など occlusionFlip を通らないステップでは
    /// false(意味を持つのは assert のみ)。後発の追加フィールドで Optional = 旧クライアント互換
    public var guarded: Bool?

    public init(kind: String) {
        self.kind = kind
    }

    /// NDJSON 1 行にエンコードする(改行を含まない)
    public func encodedLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else {
            return #"{"kind":"log","message":"(encode error)"}"#
        }
        return line.replacingOccurrences(of: "\n", with: " ")
    }

    public static func decode(line: String) -> ScenarioEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ScenarioEvent.self, from: data)
    }
}

public extension StepResult.Status {
    /// ScenarioEvent.status 用の文字列表現と詳細
    var eventStatus: (status: String, detail: String?) {
        switch self {
        case .passed:
            return ("passed", nil)
        case .passedViaFallback(let locator):
            return ("passedViaFallback", "resolved via fallback \(locator.summary)")
        case .healed(let locator):
            return ("healed", "self-healed: \(locator.summary)")
        case .failed(let reason):
            return ("failed", reason)
        case .skipped(let reason):
            return ("skipped", reason)
        case .inconclusive(let reason):
            return ("inconclusive", reason)
        }
    }
}
