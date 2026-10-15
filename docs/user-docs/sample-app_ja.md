# サンプルアプリの準備

[in English](sample-app.md)

クイックスタートで使うサンプルアプリ
([sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile)。Compose Multiplatform の EC 買い物アプリ)を
セットアップします。

## 前提条件

[はじめに(インストール)](getting-started_ja.md)が完了していること。

## AIへの指示文

```text
https://github.com/wave1008/sut-ec-mobile をこのフォルダの隣に clone して、このフォルダで bash ../sut-ec-mobile/fleetest/prepare.sh を実行して。
シェルの設定ファイルは変更しないで。終わったらスクリプトの最後の出力を報告して。
```

スクリプト(`sut-ec-mobile/fleetest/prepare.sh`)は次の順に進め、済んでいる段は飛ばします。何度実行してもかまいません。

1. Apple Silicon の Mac と、作業フォルダで実行していることを確かめる
2. Apple Container が無ければ Homebrew でインストールする
3. コンテナのランタイムを起動する(初回は Linux カーネルを取得します)
4. サーバーと PostgreSQL のイメージを取得する(サーバーは GitHub Container Registry に公開済みのイメージなので、手元でビルドしません)
5. テストプロジェクト `project1` が無ければ作り、サーバーの宣言(`compose.yaml`)を
   `TestProjects/project1/workspace/scripts/` に置く

- サーバーは実行のたびに fleetest が起動して止めます。Mac を再起動しても、起動し直す操作は要りません。
- DB は実行のたびに空から作られ、初期データはサーバーが起動時に入れます。
- サーバーの新しい版を取り込むには、`sut-ec-mobile` で `git pull` してから、同じスクリプトをもう一度実行します。
- clone したリポジトリは、[クイックスタート](quick-start_ja.md)でアプリをビルドするときにも使います。
- 宣言の中身は [sut-ec-mobile/fleetest/compose.yaml](https://github.com/wave1008/sut-ec-mobile/blob/main/fleetest/compose.yaml)、
  書き方は[アプリが依存するサービス](reference/writing/services_ja.md)にあります。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

作業フォルダで実行します。

```bash
git clone https://github.com/wave1008/sut-ec-mobile.git ../sut-ec-mobile
bash ../sut-ec-mobile/fleetest/prepare.sh
```

テストプロジェクトの名前を変えるときは、`bash ../sut-ec-mobile/fleetest/prepare.sh <名前>` のように渡します。

</details>

次へ: [クイックスタート](quick-start_ja.md)

### Link
- [index](index_ja.md)
- [はじめに(インストール)](getting-started_ja.md)
- [クイックスタート](quick-start_ja.md)
