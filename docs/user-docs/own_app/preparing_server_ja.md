# アプリが依存するサーバーを用意する

[in English](preparing_server.md)

自分のアプリ(例: テストプロジェクト myshop)が使うサーバー・DB・スタブを、コンテナにして fleetest に宣言します。
既存のサーバーへそのまま接続するだけなら要りません。宣言の読み方と起動の流れは、サンプルアプリでの[チュートリアル](../tutorial/preparing_app_server_ja.md)にあります。

## 1. サーバーを宣言して確かめる

### AIへの指示文

```text
<サーバーのフォルダ> の Dockerfile からイメージ myapp-server:local をビルドし、fleetest のテストプロジェクト myshop の
TestProjects/myshop/workspace/scripts/compose.yaml に宣言して。Dockerfile が無ければ作って(ビルド段と実行段を分け、
実行段には healthcheck に使う bash を入れる)。公開ポートは 127.0.0.1:8080。healthcheck を書いて。
Apple Container を使うなら、先にビルダー VM をメモリ 3 GB にして。
アプリの接続先は、iOS Simulator 向けのビルドでは http://127.0.0.1:8080、Android Emulator 向けでは http://10.0.2.2:8080 に
なるようビルド設定で切り替えられるようにして、両方ビルドし直してアプリプロファイルのパスを更新して。
fleetest services up --project myshop --profile ios-run で起動を確かめ、/health が ok を返すことを確認したら services down して、結果を報告して。
```

## 2. アプリの接続先を合わせる

iOS Simulator 向けは 127.0.0.1、Android Emulator 向けは 10.0.2.2 を向けます(上の指示文に含めてあります)。
実機はこの Mac の LAN アドレスに向けます(マシン設定 `services.publishForPhysicalDevices` も要ります。
[アプリの反応の速さを測る](../response/measuring_app_response_ja.md)のステップ 2〜3 に実例)。

## 3. 自分で書く必要があるもの

AIアシスタントには書かせません。

- パスワード・トークンなどの秘密は `~/.config/fleetest/secrets/<プロジェクト>.env` に置きます。
- コンテナは外部ネットワークへ出られません。出す先のドメインはマシン設定の `sandbox.allowedDomains` に書きます。

サーバーを直したら、同じ名前でイメージをビルドし直すよう指示します。

関連:

- [アプリが依存するサービス](../reference/writing/services_ja.md)
- [シナリオから外部へ通信する](../reference/writing/network_access_ja.md)
- [自分で機能を足す](../reference/writing/extending_ja.md)

次へ: [ログインが必要なアプリをテストする](logging_in_ja.md)

### Link
- [index](../index_ja.md)
