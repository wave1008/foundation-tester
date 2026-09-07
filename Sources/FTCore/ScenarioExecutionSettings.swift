// ScenarioExecutionSettings.swift
// 実行経路(runParallel/runSequential → RunOrchestrator → ScenarioRunner.runOne →
// ScenarioHost.run)が**解いて渡さず**そのまま運ぶ実行時設定の束。層ごとに引数へ解くと、
// 渡し忘れがコンパイルでも実行でも見えないまま**その層の既定へ静かに落ちる**。
public struct ScenarioExecutionSettings: Sendable, Equatable {
    public var fm: FMConfig
    /// **親スイッチ `ocr` を掛けた後の実効値**(プロファイルの `ocrFalsePositiveCheck`)であって
    /// 親スイッチそのものではない。OCR の用途が増えたらこの Bool を再利用せず欄を足す
    public var occlusionOCR: Bool
    public var containerInference: Bool
    public var defaultTimeout: Double?
    public var scenarioTimeout: Int?

    /// 既定値はこの1箇所だけに置く。他の層(ScenarioHost/RunOrchestrator/CLI)に既定を書かない。
    /// `homeOnStart` はデバイスに触る工程の設定なのでここには入れない
    public init(fm: FMConfig = FMConfig(), occlusionOCR: Bool = true,
                containerInference: Bool = true, defaultTimeout: Double? = nil,
                scenarioTimeout: Int? = nil) {
        self.fm = fm
        self.occlusionOCR = occlusionOCR
        self.containerInference = containerInference
        self.defaultTimeout = defaultTimeout
        self.scenarioTimeout = scenarioTimeout
    }

    public init(_ settings: DeviceIndependentRunSettings) {
        self.init(fm: settings.fm, occlusionOCR: settings.ocrFalsePositiveCheck,
                  containerInference: settings.containerInference,
                  defaultTimeout: settings.defaultTimeout, scenarioTimeout: settings.scenarioTimeout)
    }

    public init(_ resolved: ResolvedProfile) {
        self.init(fm: resolved.fm, occlusionOCR: resolved.ocrFalsePositiveCheck,
                  containerInference: resolved.containerInference,
                  defaultTimeout: resolved.defaultTimeout, scenarioTimeout: resolved.scenarioTimeout)
    }
}
