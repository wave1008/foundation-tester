# サーバーを確かめる

[in English](preparing_app_server.md)

SUT Store のサーバー(サーバー + PostgreSQL)は、クイックスタートで fleetest に宣言済みです。宣言したサーバーは、
`fleetest run` のたびに自動で起動し、終わると止まります。仕様の細部は[アプリが依存するサービス](../reference/writing/services_ja.md)です。

## 1. 宣言を見る

### AIへの指示文

```text
fleetest のテストプロジェクト project1 の TestProjects/project1/workspace/scripts/compose.yaml を読んで、
どんなサーバーが宣言されているか、アプリはどこへ接続するか(iOS Simulator と Android Emulator それぞれ)を説明して。
ファイルは変更しないで。
```

見えるもの: サーバーと PostgreSQL の2つが宣言され、アプリの接続先は iOS Simulator が 127.0.0.1:8090・Android Emulator が 10.0.2.2:8090 だと説明されます。

## 2. 起動して確かめる

### AIへの指示文

```text
fleetest services up --project project1 --profile ios-run でサーバーを起動して、公開ポートの /health が ok を返すことを確かめて。
確かめたら services down して、結果を報告して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest services up --project project1 --profile ios-run
curl http://127.0.0.1:8090/health     # 印字された公開ポートへ
../foundation-tester/.build/debug/fleetest services down --project project1 --profile ios-run
```

</details>
<br>

見えるもの: `services up` が公開ポートを印字し、`healthcheck` が通るまで待ってから戻ります。`/health` は `{"status":"ok"}` を返します。

関連: [アプリが依存するサービス](../reference/writing/services_ja.md)・[シナリオから外部へ通信する](../reference/writing/network_access_ja.md)・[自分で機能を足す](../reference/writing/extending_ja.md)

次へ: [テストを作る](creating_tests_ja.md)

### Link
- [index](../index_ja.md)
