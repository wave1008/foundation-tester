# AIアシスタントへの指示の仕方

[in English](asking_ai.md)

fleetest は、Claude Code などの AIアシスタントへ**自然言語で指示して**使います。シナリオ(AIアシスタントが書く Swift のファイル)や MCP のツールを、あなたが読み書きする必要はありません。
まだ一度も動かしていなければ、先に[クイックスタート](../quick-start_ja.md)を通してください。

## 指示できること

- デバイスを増やす → [デバイスを用意する](preparing_app_and_devices_ja.md)
- サーバーの宣言を読んで起動を確かめる → [サーバーを確かめる](preparing_app_server_ja.md)
- テストを作る・足す → [テストを作る](creating_tests_ja.md)
- テストを実行する → [テストを実行する](running_tests_ja.md)
- 結果を要約し、失敗の原因を調べる → [結果を読み、失敗を調べる](investigating_failures_ja.md)
- フォルダで分けて回す → [スモークと回帰を分けて回す](smoke_and_regression_ja.md)

## 指示の型

- **対象を絞る**: 1回の依頼で扱うのは1画面か1つの操作の流れにします。
- **OS とデバイスを添える**: 実行プロファイル名(`ios-run` など)を書くのが一番確実です。
- **完了条件を書く**: 「作成したシナリオのファイル名を報告したら終わりにして」のように、どこまでやるかを書きます。
- **会話に依存しない文にする**: 「さっきのアプリで」ではなく、アプリの名前(SUT Store)や画面名で書きます。
- **判断は人が持つ**: 調査と修正は分けます。

```text
fleetest のテストプロジェクト project1 の失敗の原因を調べて報告して。シナリオはまだ直さないで。
```

できあがったテストの再生には AI を使いません(毎回同じ動きになります)。

Claude Code 以外の AIアシスタントでも使えます: [Claude Code 以外の AIアシスタント](../reference/tools/other_agents_ja.md)

次へ: [デバイスを用意する](preparing_app_and_devices_ja.md)

### Link
- [index](../index_ja.md)
