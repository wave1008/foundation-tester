// ScenarioExecutionSettings.swift
// 実行経路(runParallel/runSequential → RunOrchestrator → ScenarioRunner.runOne →
// ScenarioHost.run)が**解いて渡さず**そのまま運ぶ実行時設定の束。層ごとに引数へ解くと、
// 渡し忘れがコンパイルでも実行でも見えないまま**その層の既定へ静かに落ちる**。
public struct ScenarioExecutionSettings: Sendable, Equatable {
    public var fm: FMConfig
    /// ロケータ自己修復(指紋照合)。FM を使わないので `fm` の外に置く
    public var heal: Bool
    /// OCR を使ったテキストの視覚検証の実効値(プロファイルの `ocrTextOcclusionCheck`)。
    /// OCR の用途が増えたらこの Bool を再利用せず欄を足す
    public var occlusionOCR: Bool
    /// checkIsON / checkIsOFF で CheckStateClassifier を優先するか(プロファイルの `preferCheckStateClassifier`)
    public var preferCheckStateClassifier: Bool
    public var containerInference: Bool
    /// 環境で正解が変わる既定の束(`defaultTimeout` 含む)。子プロセスへは `--tunables` で運ぶ
    public var tunables: RunTunables
    public var scenarioTimeout: Int?
    /// 実行プロファイル名(`LastResultsStore` が `(project, profile)` 単位で `--failed` の記録を
    /// 分けるための鍵)。**profile-less な run(`DeviceIndependentRunSettings` 経由)は
    /// 意図的に nil のまま** —— そもそも profile という概念が無いので、専用の区分
    /// (`LastResultsStore.noProfileKey`)へ記録される。`ResolvedProfile` 経由(`--profile` あり)は
    /// 必ず `resolved.runName` を運ぶ
    public var profileName: String?

    /// 既定値はこの1箇所だけに置く。他の層(ScenarioHost/RunOrchestrator/CLI)に既定を書かない。
    /// `homeOnStart` はデバイスに触る工程の設定なのでここには入れない
    public init(fm: FMConfig = FMConfig(), heal: Bool = false, occlusionOCR: Bool = true,
                preferCheckStateClassifier: Bool = true,
                containerInference: Bool = true, tunables: RunTunables = RunTunables(),
                scenarioTimeout: Int? = nil, profileName: String? = nil) {
        self.fm = fm
        self.heal = heal
        self.occlusionOCR = occlusionOCR
        self.preferCheckStateClassifier = preferCheckStateClassifier
        self.containerInference = containerInference
        self.tunables = tunables
        self.scenarioTimeout = scenarioTimeout
        self.profileName = profileName
    }

    public init(_ settings: DeviceIndependentRunSettings) {
        var t = RunTunables()
        if let v = settings.defaultTimeout { t.defaultTimeout = v }
        self.init(fm: settings.fm, heal: settings.heal, occlusionOCR: settings.ocrTextOcclusionCheck,
                  preferCheckStateClassifier: settings.preferCheckStateClassifier,
                  containerInference: settings.containerInference,
                  tunables: t, scenarioTimeout: settings.scenarioTimeout)
    }

    public init(_ resolved: ResolvedProfile) {
        var t = RunTunables()
        if let v = resolved.defaultTimeout { t.defaultTimeout = v }
        self.init(fm: resolved.fm, heal: resolved.heal, occlusionOCR: resolved.ocrTextOcclusionCheck,
                  preferCheckStateClassifier: resolved.preferCheckStateClassifier,
                  containerInference: resolved.containerInference,
                  tunables: t, scenarioTimeout: resolved.scenarioTimeout,
                  profileName: resolved.runName)
    }
}
