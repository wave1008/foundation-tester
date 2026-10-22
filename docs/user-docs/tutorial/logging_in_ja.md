# ログインが必要なアプリをテストする

[in English](logging_in.md)

テスト用アカウントを登録し、ログインの手順をまとめます。

## 1. パスワードを置く(自分で書く)

パスワードはリポジトリに入れず、この Mac のファイルに置きます。AIアシスタントには書かせません。

`~/.config/fleetest/dataset/<テストプロジェクト名>/accounts.json` に書きます。テストプロジェクト `myshop` なら次の場所です。

`~/.config/fleetest/dataset/myshop/accounts.json`:

```json
{
  "[account1]": { "password": "..." },
  "[account2]": { "password": "..." }
}
```

## 2. アカウントを登録し、ログインをまとめる

### AIへの指示文

```text
fleetest のテストプロジェクト myshop に、テスト用アカウントを登録して。
TestProjects/myshop/dataset/accounts.json に、[account1] は id が alice@example.com、[account2] は id が bob@example.com で登録し、
パスワードは書かないで(この Mac の ~/.config/fleetest/dataset/myshop/accounts.json に置いてある)。
My Shop のログインの手順を独自コマンド login にまとめ、account() でアカウントを引いて使うようにして。
```

見えるもの: シナリオには ID もパスワードも書かれず、`login` と `account("[account1].id")` のような呼び出しだけが並びます。

## 3. 並列で回すときはアカウントを分ける

同じアカウントを複数のデバイスで同時に使うと、カートや履歴などサーバー側の状態が混ざってテストが落ちます。

### AIへの指示文

```text
fleetest のテストプロジェクト myshop で、カートや注文履歴などサーバー側の状態を変えるシナリオが、同じアカウントを使っていないか確かめて。
使っていたら、シナリオごとに別のアカウントを使うように直して。足りないアカウントは一覧にして報告して(パスワードは私が置く)。
```

## パスワードをレポートに残さない(任意)

既定では、入力したパスワードがレポートと実行ログにそのまま残ります。この Mac の `~/.config/fleetest/config.json` に
`"redactAccountValues": true` を自分で書くと、`account()` の値が `***` に伏せられます(スクリーンショットに写った文字は伏せられません)。

詳しく: [テストデータ・アカウント](../reference/commands/dataset_ja.md)・[独自コマンド](../reference/testclass/custom_commands_ja.md)・[テストコードを書くときの便利機能](../reference/writing/helpers_ja.md)

次へ: [テストを作る](creating_tests_ja.md)

### Link
- [index](../index_ja.md)
