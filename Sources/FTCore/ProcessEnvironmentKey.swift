// ProcessEnvironmentKey.swift
// 複数のモジュールが書く・読む環境変数の名前(**唯一の定義**)。1つのモジュールの中で閉じる名前は持ち主の型に置く
// (`AppFrameworkLedger.directoryOverrideKey` 等)。生の "FT_…" を2つ以上のファイルに書くと、片方の綴りがずれたときに
// 黙って効かなくなる(サンドボックスの一覧から外れる等)—— `EnvironmentKeyLiteralTests` がソース走査で落とす

public enum ProcessEnvironmentKey {
    /// ブリッジの待受ポート。書き手は BridgeLauncher(XCUITest ランナー)・InAppLauncher(in-app)。
    /// 読み手は別ビルドの Runner/FleetestRunnerUITests と InAppBridge/Sources(文字列のまま持つ)
    public static let port = "FT_PORT"
    /// ブリッジを起動したクローンのルート(他のクローンのブリッジを取り違えない)。読み手は Runner と InAppBridge
    public static let ownerRepo = "FT_OWNER_REPO"
    /// WebView の DOM 読みの殺しスイッチ(`off` で無効)。in-app へは InAppLauncher が引き継ぐ
    public static let webViewDOM = "FT_WEBVIEW_DOM"
    /// ブラウザ(Safari / Chrome)の DOM 読みの殺しスイッチ(`off` で無効)
    public static let browserDOM = "FT_BROWSER_DOM"
    /// ブリッジの無操作での自己終了までの秒(`BridgeAPI.resolvedBridgeTTLSeconds`)
    public static let bridgeTTL = "FT_BRIDGE_TTL"
    /// ブリッジの処理時間の記録(`1` で有効。診断用)
    public static let bridgeTiming = "FT_BRIDGE_TIMING"
    /// シナリオ実行パッケージのルートの差し替え(MCP・掃除の子が親から渡す)
    public static let packageRoot = "FT_PACKAGE_ROOT"
    /// ツール(このリポジトリのクローン)のルートの差し替え。受け手の `.mcp.json` の `env` にも書かれる
    public static let toolRoot = "FT_TOOL_ROOT"
    /// シミュレータの操作手段。`simctl` = CoreSimulator を直に使わない(サンドボックスの子)
    public static let simulatorControl = "FT_SIMULATOR_CONTROL"
    /// occlusion-guard の FM 段の crop の書き出し先(FTFoundationModels が書く・サンドボックスが置き場を確かめる)
    public static let occlusionDumpDir = "FT_OCCLUSION_DUMP_DIR"
}
