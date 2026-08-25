# 並列実行

## 実行プロファイルを使う場合

**並列数 = 解決後のデバイス数**です。実行プロファイルの各デバイスが1ワーカーになり、シナリオは
その間で分配されます。iOS は稼働中のブリッジを再利用し、不足分だけ起動します。実行プロファイルの
`devices` に iOS/Android を混在させれば、1回の実行で両 OS を同時にテストできます
([profiles_ja.md](../project/profiles_ja.md)参照)。

```bash
fleetest run --project SampleApp --profile all
```

`platform:` を宣言していないシナリオは、その実行の既定 OS(ワーカーが居る最初のプラットフォーム。
通常 iOS デバイスがあれば `ios`)で走ります。**`platform:` を明示していて、その OS が実行の
デバイスに含まれていないシナリオは、キューに入らずスキップされます** —— 同じプロファイルの
もう一方の OS のデバイスは、そのシナリオぶんは空回りするだけです。プラットフォーム非依存の
シナリオを両 OS で回すには、`--profile ios` と `--profile android` を別々に実行してください。

## 実行プロファイルを使わない場合(手動 `--ports`)

シミュレータごとに別ポートでブリッジを起動し、ポート一覧を `run` に渡します。

```bash
fleetest bridge up --device "iPhone 17 Pro"                          # port 8123
fleetest bridge up --device "iPhone 17 Pro Max" --port 8124 --skip-build
xcrun simctl install "iPhone 17 Pro Max" <対象アプリ.app>            # 各デバイスにアプリを入れる

fleetest run --ports 8123,8124          # シナリオをワーカーに自動分配
fleetest bridge down --all              # 全ブリッジ停止
```

同じ実行に Android シナリオがあれば専用ワーカーが自動で立ちます(1シナリオ=1サブプロセスで
分離されるため、プラットフォームは混ざりません)。

## 目安

- 実測(M1 Max): 3本逐次 55.2秒 → 2+1並列 31.2秒(壁時間 ≒ 最長シナリオ)
- 目安の並列数: iOS 2 + Android 2 が sweet spot(3+3 は利得ゼロ)
- コールドブート直後のシミュレータはアクセシビリティ IPC がタイムアウトしやすいです。ワーカーは
  開始時に snapshot ウォームアップを自動で行いますが、それでも落ちる場合は `bridge up` の後に
  一度手動で `launch`+`snapshot` してから実行してください。

## `--broadcast`

`--broadcast` はシナリオを分配**しない**唯一の例外です。選んだシナリオを、分配ではなく実行
プロファイルの**全デバイス**で1回ずつ実行します(warmup 等の用途)。`--profile` は必須で、
`--device` で対象デバイスを絞れます。同じ `scenarioID` が台数ぶん並ぶため、結果は `worker` 欄で
区別します([results_analysis_ja.md](./results_analysis_ja.md)参照)。

## 並列実行が関わる他の場所

- VSCode 拡張も `fleetest.profile` 設定を通じて同じ並列実行を行います
  ([vscode-fleetest/README.md](../../../vscode-fleetest/README.md)の「並列実行とログレーン」参照)。
- LPT 順序付け(実績時間の長い順に投入)は直近の実行履歴でワーカー間の負荷を均します。
  `--no-lpt`/`--lpt-history-runs` で制御できます([running_scenarios_ja.md](./running_scenarios_ja.md)参照)。
- 決定的再生は FM を呼ばないため並列にスケールします。`screenLooksLike` と失敗時トリアージは
  オンデバイス FM(マシンに1本)を呼ぶため、デバイス台数に関わらずそこで律速されます。

### Link
- [index](../index_ja.md)
