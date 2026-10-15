# アプリが依存するサーバーを用意する

[in English](preparing_app_server.md)

自分のアプリが使うサーバー・DB・スタブをコンテナにして、fleetest に宣言する一般的な流れです。
仕様の細部は[アプリが依存するサービス](../reference/writing/services_ja.md)にあります。
サンプルアプリでの実例は[サンプルアプリの準備](../sample-app_ja.md)です。

## 考え方

- サーバーは `TestProjects/<プロジェクト>/workspace/scripts/compose.yaml` に宣言します。
  fleetest が**実行のたびに起動し、終わったら止めます**。毎回同じ状態で始まり、起動の完了は `healthcheck` で待ちます。
- シナリオや `run-setup.sh` からサーバーを起こしません。宣言が無ければ何も起きません。

## 手順

### ① Dockerfile を書く

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

### ② イメージをビルドする

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

### ③ compose.yaml を書く

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

### ④ アプリの接続先を合わせる

| 実行先 | アプリから見たサーバーの宛先 |
|---|---|
| iOS Simulator | `127.0.0.1` |
| Android Emulator | `10.0.2.2` |
| 実機 | この Mac の LAN アドレス(マシン設定 `services.publishForPhysicalDevices` も要ります) |

### ⑤ 確かめる

```bash
../foundation-tester/.build/debug/fleetest services up --profile <実行プロファイル>
curl http://127.0.0.1:8080/health     # 印字された公開ポートへ
../foundation-tester/.build/debug/fleetest services down --profile <実行プロファイル>
```

## サーバーを直したとき

同じ名前でビルドし直します。fleetest は手元のイメージを使い、取得しません。名前を変えたら compose.yaml も直します。

## AIアシスタントに指示する

Dockerfile がある場合:

```text
<サーバーのフォルダ> の Dockerfile からイメージ myapp-server:local をビルドし、TestProjects/project1/workspace/scripts/compose.yaml に宣言して。公開ポートは 127.0.0.1:8080。healthcheck を書いて。fleetest services up --profile ios-run で起動を確かめたら services down して、結果を報告して。
```

Dockerfile が無い場合:

```text
<サーバーのフォルダ> のサーバー用の Dockerfile を作り、そこからイメージ myapp-server:local をビルドして、TestProjects/project1/workspace/scripts/compose.yaml に宣言して。公開ポートは 127.0.0.1:8080。healthcheck を書いて。fleetest services up --profile ios-run で起動を確かめたら services down して、結果を報告して。
```

## 関連

- 秘密(パスワード・トークン)は `~/.config/fleetest/secrets/<プロジェクト>.env` に置きます([アプリが依存するサービス](../reference/writing/services_ja.md))。
- コンテナは外部ネットワークへ出られません。出すドメインは `sandbox.allowedDomains` に書きます([シナリオから外部へ通信する](../reference/writing/network_access_ja.md))。
- 名前付きボリュームは `fleetest services reset` まで残ります。
- `run-setup.sh` はデータ投入だけに使います([自分で機能を足す](../reference/writing/extending_ja.md))。
- レジストリに届かない Mac では、別の Mac で `container image save` / `docker save` した tar を `fleetest services load <file>` で読み込みます。

次へ: [テストを作る](creating_tests_ja.md)

### Link
- [index](../index_ja.md)
