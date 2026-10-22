# アプリが依存するサーバーを用意する

[in English](preparing_app_server.md)

自分のアプリが使うサーバー・DB・スタブをコンテナにして、fleetest に宣言します。宣言すると、`fleetest run` のたびに
サーバーが自動で起動し、終わると止まります。既存のサーバーにそのまま接続するだけなら、このページは要りません。
仕様の細部は[アプリが依存するサービス](../reference/writing/services_ja.md)、実例は
[sut-ec-mobile/fleetest/compose.yaml](https://github.com/wave1008/sut-ec-mobile/blob/main/fleetest/compose.yaml) です。

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

見えるもの: `services up` が公開ポートを印字し、`healthcheck` が通るまで待ってから戻ります。

## 2. 段階を踏んで頼む(任意)

1 の指示文を分けて頼みたいときの指示文です。

### ① Dockerfile

```text
<サーバーのフォルダ> のサーバー用の Dockerfile を作って。ビルド段と実行段を分けて、実行用のイメージを小さくして。
実行段には healthcheck に使う bash を入れて。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```dockerfile
FROM gradle:8-jdk17 AS build
WORKDIR /src
COPY . .
RUN gradle --no-daemon installDist

FROM eclipse-temurin:17-jre
COPY --from=build /src/build/install/app /app
EXPOSE 8080
CMD ["/app/bin/app"]
```

</details>

### ② イメージのビルド

```text
<サーバーのフォルダ> の Dockerfile からイメージ myapp-server:local をビルドして。Apple Container を使うなら、先にビルダー VM をメモリ 3 GB にして。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
container builder stop && container builder start --cpus <N> --memory 3g
container build -t myapp-server:local .
```

CPU は Mac のコア数(`sysctl -n hw.ncpu`)の 1/4 を切り上げた数です。Docker なら `docker build -t myapp-server:local .` です。

</details>
<br>

見えるもの: `container image list`(Docker なら `docker images`)に `myapp-server:local` が並びます。

### ③ compose.yaml

```text
fleetest のテストプロジェクト myshop の TestProjects/myshop/workspace/scripts/compose.yaml に、イメージ myapp-server:local のサーバーと PostgreSQL を宣言して。
公開ポートは 127.0.0.1:8080。両方に healthcheck を書き、DB の起動完了を待ってからサーバーを起動するようにして。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: dev
      # Apple Container のボリュームは根に lost+found があるので、サブディレクトリを使う
      PGDATA: /var/lib/postgresql/data/pgdata
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 2s
      retries: 30
  server:
    image: myapp-server:local
    depends_on:
      db:
        condition: service_healthy
    ports: ["127.0.0.1:8080:8080"]
    healthcheck:
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /health HTTP/1.0\r\n\r\n' >&3 && grep -q ok <&3"]
      interval: 3s
      retries: 60
```

</details>

### ④ アプリの接続先を合わせる

```text
My Shop のサーバーの接続先を、iOS Simulator 向けのビルドでは http://127.0.0.1:8080、Android Emulator 向けでは http://10.0.2.2:8080 になるようにビルド設定で切り替えられるようにして。両方ビルドし直して、fleetest のテストプロジェクト myshop のアプリプロファイルのパスを更新して。
```

実機はこの Mac の LAN アドレスに向けます(マシン設定 `services.publishForPhysicalDevices` も要ります。
[アプリの反応の速さを測る](../response/measuring_app_response_ja.md)のステップ 2〜3 に実例)。

### ⑤ 起動の確認

```text
fleetest services up --project myshop --profile ios-run でサーバーを起動して、/health が ok を返すことを確かめて。確かめたら services down して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest services up --project myshop --profile ios-run
curl http://127.0.0.1:8080/health     # 印字された公開ポートへ
../foundation-tester/.build/debug/fleetest services down --project myshop --profile ios-run
```

</details>

## サーバーを直したとき

```text
サーバーを直したので、<サーバーのフォルダ> からイメージ myapp-server:local を同じ名前でビルドし直して。
```

自分で書く必要があるもの(AIアシスタントには書かせません):

- パスワード・トークンなどの秘密は `~/.config/fleetest/secrets/<プロジェクト>.env` に置きます。
- コンテナは外部ネットワークへ出られません。出す先のドメインはマシン設定の `sandbox.allowedDomains` に書きます。

関連: [アプリが依存するサービス](../reference/writing/services_ja.md)・[シナリオから外部へ通信する](../reference/writing/network_access_ja.md)・[自分で機能を足す](../reference/writing/extending_ja.md)

次へ: [ログインが必要なアプリをテストする](logging_in_ja.md)

### Link
- [index](../index_ja.md)
