# サンプルアプリの準備

[in English](sample-app.md)

[はじめに(インストール)](getting-started_ja.md)が済んだ後、クイックスタートで使うサンプルアプリ
([sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile)。Compose Multiplatform の EC 買い物アプリ)の
サーバーのイメージを取得して、fleetest に宣言するまでの手順です。
サーバーは Kotlin(Ktor)と PostgreSQL でできています。

## 1. サーバーのイメージを取得する

### AIへの指示文

```text
https://github.com/wave1008/sut-ec-mobile をこのフォルダの隣に clone して。
コンテナのランタイムは Apple Container を使う。無ければ Homebrew でインストールし、container system start --enable-kernel-install を1回実行して。
container image pull ghcr.io/wave1008/sut-ec-mobile-server:latest と container image pull postgres:16-alpine を実行して。
シェルの設定ファイルは変更しないで。アプリはビルドしなくてよい。
container image ls に sut-ec-mobile-server と postgres が出ることを確かめて報告したら終わりにして。
```

- サーバーは GitHub Container Registry(GHCR)に公開済みのイメージを使うので、手元でビルドする必要はありません。
- clone したリポジトリは、[クイックスタート](quick-start_ja.md)でアプリをビルドするときに使います。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

```bash
brew install container
container system start --enable-kernel-install    # Linux カーネルの取得。1回だけ

cd ..                                              # 作業フォルダの隣に clone する
git clone https://github.com/wave1008/sut-ec-mobile.git

container image pull ghcr.io/wave1008/sut-ec-mobile-server:latest
container image pull postgres:16-alpine
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
# server は GHCR に公開済みのイメージ(手元に無ければ fleetest が取得する)。
# アプリの接続先はビルドに焼かれている(iOS Simulator = 127.0.0.1:8090 / Android Emulator = 10.0.2.2:8090)。
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: sutec
      POSTGRES_USER: sutec
      POSTGRES_PASSWORD: sutec
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sutec"]
      interval: 500ms
      timeout: 3s
      retries: 120

  server:
    image: ghcr.io/wave1008/sut-ec-mobile-server:latest
    # サーバーは DB に接続できるまで自分で待つので、DB の準備完了を待たずに続けて起動する
    depends_on:
      db:
        condition: service_started
    environment:
      DATABASE_URL: jdbc:postgresql://db:5432/sutec
      DB_USER: sutec
      DB_PASSWORD: sutec
      JWT_SECRET: dev-secret-change-me
      IMAGES_DIR: /app/mock-server/images
    ports:
      - "127.0.0.1:8090:8090"
    healthcheck:
      # イメージは Alpine で bash と curl が無いので、BusyBox の wget で /health を読む
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8090/health | grep -q '\"status\":\"ok\"'"]
      interval: 500ms
      timeout: 5s
      retries: 360
      start_period: 10s
```
````

- サーバーは実行のたびに fleetest が起動して止めます。Mac を再起動しても、起動し直す操作は要りません。
- DB は実行のたびに空から作られ、初期データはサーバーが起動時に入れます。
- サーバーの新しい版を取り込むには、作業フォルダで `fleetest services pull --refresh` を実行します(fleetest は手元にあるイメージを使い続けます)。
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
