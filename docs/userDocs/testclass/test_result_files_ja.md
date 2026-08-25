# 実行で何が出るか

run(成否問わず)は何種類かの出力を残します。このページはその置き場所の地図です。
詳細は[結果の分析](../running/results_analysis_ja.md)と
[結果 JSON のスキーマ](../../results-json.md)を参照してください。

## Markdown レポート

`TestProjects/<プロジェクト>/reports/scenario-*.md` —— シナリオ実行ごとに、成否を問わず
出力されます。コードと同じ `scene → condition/action/expectation → ステップ` の階層に加え、
トリアージの要約、失敗時点のスクリーンショット(あれば)、自己修復が働いたときのセレクタ
修正提案を含みます。

## 結果 JSON

`results/runs/<YYYY-MM>/<runID>/` に機械可読な記録が入ります。run 全体は `run.json`、
シナリオ1本ごとは `scenarios/<シナリオID>.json` です。CI のゲート判定・ダッシュボード・
スクリプトによるトリアージはここを情報源にします。全欄のリファレンスは
[結果 JSON のスキーマ](../../results-json.md)。

## JUnit XML

`ftester run --junit <パス>` を付けると、JUnit XML 形式をそのまま読める CI システム向けに
JUnit XML ファイルも追加で出力されます。

## 録画

実行プロファイルで `record: true` にすると、各デバイスの run 全体を録画したうえで、
シナリオごとに1本のクリップへ切り出して `<runDir>/recordings/` に保存します。録画自体が
失敗しても run は失敗しません。

## 自己修復キャッシュ

自己修復が有効なとき、`TestProjects/<プロジェクト>/.ftester/heal-cache.json` に実行時に
修復されたセレクタが保存されます。これにより、ソースが古いセレクタのままでも2回目以降は
AI なしで決定的に通過します。詳細は[自己修復](../running/self_healing_ja.md)を参照してください。

## 直近の結果(`--failed` 用)

`.ftester/last-results/<プロジェクト>/` には直近の run でどのシナリオが成功/失敗したかが
記録されます。`ftester run --failed` はこれを使って失敗したシナリオだけを再実行します。

## VSCode 拡張から

拡張の Test Explorer は各テストの成否を直接表示し、生成された Markdown レポートを
「レポートを開く」からそのまま開けます。

### Link
- [index](../index_ja.md)
