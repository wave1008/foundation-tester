# サンプルアプリの準備

[in English](sample-app.md)

[はじめに(インストール)](getting-started_ja.md)が済んだ後、クイックスタートで使うサンプルアプリ
([sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile)。Compose Multiplatform の EC 買い物アプリ)の
サーバーをコンテナにして、fleetest に宣言するまでの手順です。
サーバーは Kotlin(Ktor)と PostgreSQL でできています。

## 1. サーバーのイメージをビルドする

### AIへの指示文

```text
https://github.com/wave1008/sut-ec-mobile をこのフォルダの隣に clone して。
コンテナのランタイムは Apple Container を使う。無ければ Homebrew でインストールし、container system start --enable-kernel-install を1回実行して。
ビルドの前に container builder stop && container builder start --cpus <N> --memory 3g を実行して。<N> は sysctl -n hw.ncpu の値の 1/4 を切り上げた数。
sut-ec-mobile の直下で、server/Dockerfile からサーバーのイメージ sut-ec-mobile-server:local をビルドして。
container image pull postgres:16 も実行して。
シェルの設定ファイルは変更しないで。アプリはビルドしなくてよい。
container image ls に sut-ec-mobile-server と postgres が出ることを確かめて報告したら終わりにして。
```

- **ビルダー VM のメモリは 3 GB にします。** Apple Container のビルドはビルダー VM の中で動き、既定の 2 CPU / 2 GB では
  サーバーのビルド(Gradle)が止まります(25 分出力が無いまま失敗した実測があります)。2.5 GB と 3 GB で成功したので、
  失敗した 2 GB から 1 GB、成功した 2.5 GB から 0.5 GB の余裕を見た値です。
- **CPU は Mac のコア数の 1/4 を切り上げます**(`sysctl -n hw.ncpu` で見ます。8 コアなら 2、10 コアなら 3、16 コアなら 4)。
- 所要の目安は、2 CPU で約 2.5 分です。依存ライブラリの取得で外のネットワークへ出ます。
- ビルドが終わったら `container builder stop` でビルダー VM を止めてかまいません(イメージは残ります)。
- `postgres:16` を先に取っておくのは、最初の実行でイメージの取得を待たないためです。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

```bash
brew install container
container system start --enable-kernel-install    # Linux カーネルの取得。1回だけ
sysctl -n hw.ncpu                                  # コア数。<N> はこの 1/4 を切り上げた数

container builder stop && container builder start --cpus <N> --memory 3g

cd ..                                              # 作業フォルダの隣に clone する
git clone https://github.com/wave1008/sut-ec-mobile.git
cd sut-ec-mobile
container build -t sut-ec-mobile-server:local -f server/Dockerfile .

container image pull postgres:16
container image ls
```

</details>

## 2. fleetest にサーバーを宣言する

サーバーは `TestProjects/<プロジェクト>/workspace/scripts/compose.yaml` に宣言します。

### AIへの指示文

````text
TestProjects/project1/workspace/scripts/compose.yaml を次の内容で作って(フォルダが無ければ作る。テストプロジェクト project1 が無ければ先に fleetest project create project1 で作る)。作ったファイルのパスを報告したら終わりにして。

```yaml
# sut-ec-mobile のバックエンド(PostgreSQL + サーバー)。fleetest が実行のたびに起動し、healthcheck を待ってからシナリオを動かし、終わったら止める。
# server は「サンプルアプリの準備」でビルドしたイメージ(手元にあるので取得しない)。
# アプリの接続先はビルドに焼かれている(iOS Simulator = 127.0.0.1:8090 / Android Emulator = 10.0.2.2:8090)。
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: sutec
      POSTGRES_USER: sutec
      POSTGRES_PASSWORD: sutec
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sutec"]
      interval: 2s
      timeout: 3s
      retries: 30

  server:
    image: sut-ec-mobile-server:local
    depends_on:
      db:
        condition: service_healthy
    environment:
      DATABASE_URL: jdbc:postgresql://db:5432/sutec
      DB_USER: sutec
      DB_PASSWORD: sutec
      JWT_SECRET: dev-secret-change-me
      IMAGES_DIR: /app/mock-server/images
    ports:
      - "127.0.0.1:8090:8090"
    healthcheck:
      # JRE のイメージに curl が無いので、bash の /dev/tcp で /health を読む
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8090 && printf 'GET /health HTTP/1.0\r\n\r\n' >&3 && grep -q '\"status\":\"ok\"' <&3"]
      interval: 3s
      timeout: 5s
      retries: 60
      start_period: 10s
```
````

- サーバーは実行のたびに fleetest が起動して止めます。Mac を再起動しても、起動し直す操作は要りません。
- DB は実行のたびに空から作られ、初期データはサーバーが起動時に入れます。
- サーバーを更新したら、同じ名前でビルドし直します(fleetest は手元のイメージを使います)。
- 宣言の書き方は[アプリが依存するサービス](reference/writing/services_ja.md)にあります。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

作業フォルダで、フォルダを作ってファイルを書きます。

```bash
mkdir -p TestProjects/project1/workspace/scripts
```

`TestProjects/project1/workspace/scripts/compose.yaml` に、上の指示文にある YAML の内容を書きます。
テストプロジェクト `project1` が無ければ、先に `../foundation-tester/.build/debug/fleetest project create project1` で作ります
(VSCode 拡張も Reload Window 後の起動時に作ります)。

</details>

次へ: [クイックスタート](quick-start_ja.md)

### Link
- [index](index_ja.md)
- [はじめに(インストール)](getting-started_ja.md)
- [クイックスタート](quick-start_ja.md)
