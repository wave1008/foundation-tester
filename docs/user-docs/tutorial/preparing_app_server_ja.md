# アプリが依存するサーバーを用意する

[in English](preparing_app_server.md)

自分のアプリが使うサーバー・DB・スタブをコンテナにして、fleetest に宣言するまでの手順です。
Dockerfile・compose.yaml の作成とビルドは AIアシスタントに頼めます。仕様の細部は
[アプリが依存するサービス](../reference/writing/services_ja.md)、サンプルアプリでの実例は
[sut-ec-mobile/fleetest/compose.yaml](https://github.com/wave1008/sut-ec-mobile/blob/main/fleetest/compose.yaml)
([クイックスタート](../quick-start_ja.md)で使うサンプルアプリのサーバーの宣言)です。

## 考え方

- サーバーは `TestProjects/<プロジェクト>/workspace/scripts/compose.yaml` に宣言します。
  fleetest が**実行のたびに起動し、終わったら止めます**。毎回同じ状態で始まり、起動の完了は `healthcheck` で待ちます。
- シナリオや `run-setup.sh` からサーバーを起こしません。宣言が無ければ何も起きません。
- Mac にコンテナのランタイム(Apple Container か Docker)が入っていることが前提です(どちらを使うかの決まり方は
  [アプリが依存するサービス](../reference/writing/services_ja.md))。

## 手順

### ① Dockerfile を書く

サーバーのソースがあるフォルダに、Dockerfile を用意します。すでにあれば ② へ進みます。

#### AIへの指示文

```text
<サーバーのフォルダ> のサーバー用の Dockerfile を作って。ビルド段と実行段を分けて、実行用のイメージを小さくして。
実行段には healthcheck に使う bash を入れて。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

ビルド段と実行段を分けると、実行用のイメージが小さくなります。

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

`healthcheck` に使う `curl` が無いイメージでは、bash の `/dev/tcp` で読めます
(例: `test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /health HTTP/1.0\r\n\r\n' >&3 && grep -q ok <&3"]`)。

</details>
<br>

### ② イメージをビルドする

#### AIへの指示文

```text
<サーバーのフォルダ> の Dockerfile からイメージ myapp-server:local をビルドして。Apple Container を使うなら、先にビルダー VM をメモリ 3 GB にして。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

Apple Container では、先にビルダー VM の大きさを決めます。既定の 2 GB ではビルドが止まることがあるので、3 GB から始めます。
CPU は Mac のコア数(`sysctl -n hw.ncpu`)の 1/4 を切り上げた数です。

```bash
container builder stop && container builder start --cpus <N> --memory 3g
container build -t myapp-server:local .
```

ビルドが止まる(長く出力が無いまま失敗する)ときは、メモリを増やします。Docker を使うなら次の1行です。

```bash
docker build -t myapp-server:local .
```

</details>
<br>

見えるもの: `container image list`(Docker なら `docker images`)に `myapp-server:local` が並びます。

### ③ compose.yaml を書く

#### AIへの指示文

```text
TestProjects/project1/workspace/scripts/compose.yaml に、イメージ myapp-server:local のサーバーと PostgreSQL を宣言して。
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

公開ポートは `127.0.0.1` だけに束縛します。DB を待つ `depends_on` には `condition: service_healthy` を付けます。
PostgreSQL のボリュームの例は[アプリが依存するサービス](../reference/writing/services_ja.md)を参照してください。

</details>
<br>

### ④ アプリの接続先を合わせる

アプリ側のサーバーの宛先を、実行先に合わせます。宛先はビルド設定で切り替えられるようにしておくと、Simulator 用と
Emulator 用を同じソースから作れます。

| 実行先 | アプリから見たサーバーの宛先 |
|---|---|
| iOS Simulator | `127.0.0.1` |
| Android Emulator | `10.0.2.2` |
| 実機 | この Mac の LAN アドレス(マシン設定 `services.publishForPhysicalDevices` も要ります。[アプリの反応の速さを測る](../response/measuring_app_response_ja.md)のステップ 2〜3 に実例) |

#### AIへの指示文

```text
My Shop のサーバーの接続先を、iOS Simulator 向けのビルドでは http://127.0.0.1:8080、Android Emulator 向けでは http://10.0.2.2:8080 になるようにビルド設定で切り替えられるようにして。両方ビルドし直して、アプリプロファイルのパスを更新して。
```

### ⑤ 確かめる

#### AIへの指示文

```text
fleetest services up --profile ios-run でサーバーを起動して、/health が ok を返すことを確かめて。確かめたら services down して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest services up --profile <実行プロファイル>
curl http://127.0.0.1:8080/health     # 印字された公開ポートへ
../foundation-tester/.build/debug/fleetest services down --profile <実行プロファイル>
```

</details>
<br>

見えるもの: `services up` が公開ポートを印字し、`healthcheck` が通るまで待ってから戻ります。以後、`fleetest run` のたびに
サーバーが自動で起動し、終わると止まります。

## まとめて1回で頼む

①〜③と⑤は、1つの指示にまとめられます。

Dockerfile がある場合:

```text
<サーバーのフォルダ> の Dockerfile からイメージ myapp-server:local をビルドし、TestProjects/project1/workspace/scripts/compose.yaml に宣言して。公開ポートは 127.0.0.1:8080。healthcheck を書いて。fleetest services up --profile ios-run で起動を確かめたら services down して、結果を報告して。
```

Dockerfile が無い場合:

```text
<サーバーのフォルダ> のサーバー用の Dockerfile を作り、そこからイメージ myapp-server:local をビルドして、TestProjects/project1/workspace/scripts/compose.yaml に宣言して。公開ポートは 127.0.0.1:8080。healthcheck を書いて。fleetest services up --profile ios-run で起動を確かめたら services down して、結果を報告して。
```

## サーバーを直したとき

同じ名前でビルドし直します。fleetest は手元のイメージを使い、取得しません。名前を変えたら compose.yaml も直します。

```text
サーバーを直したので、<サーバーのフォルダ> からイメージ myapp-server:local を同じ名前でビルドし直して。
```

## 関連

- 秘密(パスワード・トークン)は `~/.config/fleetest/secrets/<プロジェクト>.env` に置きます([アプリが依存するサービス](../reference/writing/services_ja.md))。
  このファイルは、この Mac の人が手で書きます。
- コンテナは外部ネットワークへ出られません。出すドメインは `sandbox.allowedDomains` に書きます([シナリオから外部へ通信する](../reference/writing/network_access_ja.md))。
- 名前付きボリュームは `fleetest services reset` まで残ります。
- `run-setup.sh` はデータ投入だけに使います([自分で機能を足す](../reference/writing/extending_ja.md))。
- レジストリに届かない Mac では、別の Mac で `container image save` / `docker save` した tar を `fleetest services load <file>` で読み込みます。

次へ: [テストを作る](creating_tests_ja.md)

### Link
- [index](../index_ja.md)
