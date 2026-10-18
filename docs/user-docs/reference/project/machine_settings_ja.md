# マシン設定(config.json)

[in English](machine_settings.md)

シナリオを実行する Mac の `~/.config/fleetest/config.json` に置ける**全キー**の一覧です。
各キーの型・既定値・意味と、詳しく書いてあるページを示します。

- **設定はシナリオを実行する Mac にだけ置きます**。プロジェクト・[実行プロファイル](run_profile_ja.md)からは上書きできません。
  サンドボックスと `hooks` の設定は、`XDG_CONFIG_HOME` で別の設定ファイルへ向けることもできません(枠をシナリオ側から緩めさせないためです)。
  環境変数が優先されるキーは、下の表に書いてあります。
- **この Mac の人が手で書きます**。Claude Code には、導入時に `Edit(~/.config/fleetest/**)` の編集拒否が入ります
  (サンドボックスを外す `sandbox.disabled` などがここにあるためです)。ただし、作業フォルダが fleetest のクローンの内側にある構成では、
  この拒否は書かれません。中身を読んで説明してもらうことは AI に頼めますが、書き換えは自分で行ってください。
- **知らないキーや壊れた JSON があると、シナリオを起動せずにエラーで止まります**。止まるのは `sandbox`・`hooks`・`services` の欄の中の
  知らないキーと、ファイル全体が JSON として読めないときです(足したはずの制限が黙って消えた状態で走らせないためです)。
  たとえば `"sandbox": { "allowedDomain": [...] }`(`s` の書き忘れ)は、エラーになって気づけます。
- **設定は次のシナリオの起動から効きます**。起動し直しは要りません。

## 例

```json
{
  "sandbox": {
    "allowedDomains": ["api.example.com:443"],
    "denyRead": ["~/work/secrets"],
    "allowDirectAdb": false,
    "disabled": false
  },
  "hooks": {
    "writablePaths": ["~/work/shared-fixtures"]
  },
  "services": {
    "runtime": "docker",
    "buildSources": ["/Users/me/work/server-src"],
    "publishForPhysicalDevices": "192.168.1.10"
  },
  "redactAccountValues": true
}
```

## 全キー

| キー | 型 | 既定 | 意味 | 詳細 |
|---|---|---|---|---|
| `sandbox.allowedDomains` | 文字列の配列 | なし(外部へは一切出られない) | シナリオから通してよい外部の宛先(`api.example.com:443`・`*.example.org`) | [サンドボックスの既定](../running/sandbox_access_ja.md)・[シナリオから外部へ通信する](../writing/network_access_ja.md) |
| `sandbox.denyRead` | 文字列の配列 | なし | 内蔵の「読めない場所」の一覧に**足す**読ませない場所(置き換えない。`~` を使えます) | [サンドボックスの既定](../running/sandbox_access_ja.md) |
| `sandbox.allowDirectAdb` | 真偽値 | `false` | `true` でシナリオが adb と bundletool を自分で使えます。そのぶん Emulator の中のシェル経由で外部へ出られ、繋がった全 Android 端末に届きます | [サンドボックスを確かめて、必要な穴をあける](../../security/sandbox_ja.md) |
| `sandbox.disabled` | 真偽値 | `false` | `true` でこの Mac ではサンドボックスを外します | [サンドボックスを確かめて、必要な穴をあける](../../security/sandbox_ja.md) |
| `hooks.writablePaths` | 文字列の配列 | なし(`<workspace>/data/` だけ) | `run-setup.sh` / `run-teardown.sh` が書ける追加の場所(絶対パスか `~/` 始まり) | [run の前後で処理を走らせる](../writing/extending_ja.md#run-の前後で処理を走らせる) |
| `services.runtime` | `"docker"` か `"apple"` | 未設定 | compose.yaml のサービスに使うコンテナのランタイム。未設定のときは使えるものを探し、ちょうど1つだけ使えるならそれを使います。両方使えるときは黙って選ばずエラーにするので、その Mac で名指ししてください | [アプリが依存するサービス](../writing/services_ja.md) |
| `services.buildSources` | 文字列の配列 | なし | `build:` の context として `scripts/` の下に加えて許す場所(絶対パス。`~` は展開しません。読み取り専用でマウントしてビルドします) | [アプリが依存するサービス](../writing/services_ja.md) |
| `services.publishForPhysicalDevices` | 文字列(IPv4) | なし | 実機を含む run でサービスの公開ポートを全インターフェースに束縛することへの同意。この Mac の LAN の IPv4 アドレスを書き、実機がそのアドレスで届きます | [アプリが依存するサービス](../writing/services_ja.md)・[アプリの反応の速さを測る](../../response/measuring_app_response_ja.md) |
| `redactAccountValues` | 真偽値 | `false`(伏せない) | `true` で `account()` の値をレポート・実行ログ・結果 JSON で `***` に伏せます | [テストデータ・アカウント](../commands/dataset_ja.md) |
| `hostLoadPacing` | オブジェクト | 有効(`disabled` なし) | Mac の CPU 負荷が高い瞬間に、画面を変える操作の前へ短い待ちを1回入れる「ステップの減速」。`disabled: true` で止め、`tiers`(`cpuPercentAtLeast` と `delayMs` の組の配列)で段を変えます | [並列実行](../running/parallel_execution_ja.md) |
| `hostLoadPacing.tiers` | 配列 | CPU 90% 以上で 200ms・95% 以上で 1000ms | 空の配列 `[]` は「段が無い = 待たない」です。値が正しくないときは既定の段で動き、実行の開始時に警告が1回出ます | [並列実行](../running/parallel_execution_ja.md) |
| `retention` | オブジェクト | 下の表のとおり | ログ・録画・レポートなどの保持容量。欄が無いのは「全部既定」で、「掃除しない」ではありません | [長く使うためのメンテナンス](../../in_action/maintenance_ja.md)・[VSCode 拡張](../tools/vscode_extension_ja.md) |
| `remoteHosts` | 配列 | なし | リモート実行のランナー機の登録簿(`machine`・`host`・`dir`・`fmConcurrency`・`color`・`enabled`・`developerDir`) | [Mac を追加する](../../fleet/adding_mac_ja.md)・[リモート実行](../../fleet/remote_runners_ja.md) |
| `developmentTeam` | 文字列 | なし(実機のビルドはできない) | iOS 実機ブリッジの署名に使う Apple Developer の Team ID。環境変数 `FT_DEVELOPMENT_TEAM` が優先されます | [実機を追加する](../../fleet/adding_physical_devices_ja.md) |
| `bundleIDPrefix` | 文字列 | `com.example` | iOS 実機ブリッジの bundle id の前置き。他チームの登録と重ならない値にします。環境変数 `FT_BUNDLE_ID_PREFIX` が優先されます | [実機を追加する](../../fleet/adding_physical_devices_ja.md) |
| `issuerId` | 文字列 | `ユーザー名@ホスト名` | リモート実行で「誰が起動したか」を記す自己申告の名前(認証ではありません)。環境変数 `FT_ISSUER` が優先されます | [リモート実行](../../fleet/remote_runners_ja.md)・[実機を追加する](../../fleet/adding_physical_devices_ja.md) |
| `fmConcurrency` | 整数 | `1` | **この Mac** で Apple Intelligence(Foundation Models)を同時に呼ぶ数。1 以上の整数。環境変数 `FT_FM_CONCURRENCY` が優先されます。リモートのランナー機のぶんは、その機械の登録(`remoteHosts` の `fmConcurrency`)に置きます | 調整の根拠は保守者向けの `docs/performance-tuning.md` |
| `defaultProject` | 文字列 | なし | `--project` を省略したときに使うプロジェクト名。プロジェクトの改名・削除(`fleetest project`)に合わせて自動で直ります | [プロジェクトの作成](creating_project_ja.md) |
| `lastRunProfile` | オブジェクト(プロジェクト名 → 実行プロファイル名) | なし | 拡張が最後に選んだ実行プロファイルを覚えておく欄です。**拡張が書くので、手で編集しません** | — |
| `localMachineEnabled` | 真偽値 | `true` | 拡張の設定タブの「マシン有効」(この Mac の行)。`false` のときだけ保存されます。**拡張が書くので、手で編集しません** | [VSCode 拡張](../tools/vscode_extension_ja.md) |

### `retention` の中身

値の単位はバイトで、カテゴリ全体で保持してよい上限です(run 単位でも日単位でもありません)。使用量が上限の 90% を超えたら、
古いものから 90% まで消えます。欄は拡張の「設定」タブの「ログ・録画」からも変えられます。

| キー | 既定 | 対象 |
|---|---|---|
| `deviceCapturesMaxBytes` | 2 GiB | Simulator のテスト実行が残す添付 |
| `recordingsMaxBytes` | 50 GiB | run の録画 |
| `eventLogsMaxBytes` | 2 GiB | シナリオごとの実行ログ |
| `reportsMaxBytes` | 2000 MiB | プロジェクトの `reports/` のレポート(Markdown とスクリーンショット) |
| `logsMaxBytes` | 100 MiB | ブリッジなどの `.fleetest/*.log` |
| `xcresultMaxBytes` | 5 GiB | XCUITest ランナーの結果の束 |
| `sweepAfterRun` | `true` | run の完了後にバックグラウンドで自動掃除するか |

下限があり、これより小さい上限は受け付けません(`deviceCapturesMaxBytes` 1 GiB・`recordingsMaxBytes` 2 GiB・
`eventLogsMaxBytes` 100 MiB・`reportsMaxBytes` 100 MiB・`logsMaxBytes` 10 MiB・`xcresultMaxBytes` 1 GiB)。

### Link
- [index](../../index_ja.md)
