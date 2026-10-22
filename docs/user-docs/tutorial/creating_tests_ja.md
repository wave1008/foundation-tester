# テストを作る

[in English](creating_tests.md)

テストは AIアシスタントに作らせます。できあがるのは `TestProjects/project1/scenarios/` 配下の Swift ファイル(シナリオ)です。サンプルアプリ(SUT Store)で順に試せます。

## 1. 基本ルートのテストを作る

最初の1本に向いています。正常に進む流れだけを1本作ります(エラーの場合などは、あとで「既存のテストに足す」で足します)。

### AIへの指示文

```text
fleetest のテストプロジェクト project1 で、SUT Store の基本ルート(正常に進む流れ)のテストを1本作成して。
検索画面で商品を探して(カテゴリで絞り込んでよい)、商品を開いてカートに追加し、カートにその商品が入っていることを確かめる。ログインは不要。
作ったら、iOS(ios-run)で実行して確かめて。
```

AIアシスタントは、コンパイルとデバイス無しの検証(dry-run)、デバイスでの実行まで行い、結果を報告します。

<img src="../images/tutorial/ja/ai_workflow.png" width="720" alt="画面を操作して読む、シナリオを書く、コンパイル、dry-run、デバイスで実行、結果を報告の順に進む">

## 2. 既存のテストに足す

### AIへの指示文

```text
fleetest のテストプロジェクト project1 の SUT Store の基本ルートのテストに、ログインなしで、商品詳細で数量を3にしてカートに追加するケースを追加して。
カートでその商品の数量が3になっていることを確かめる。作ったら、iOS(ios-run)で実行して確かめて。
```

指示した挙動がアプリに無いときは、実際の挙動が報告され、仕様どおりかの判断を求められます。

もっと詳しく: [テストクラスの作成](../reference/testclass/creating_testclass_ja.md)・[セレクタ式](../reference/selector/selector_expression_ja.md)・[壊れにくいシナリオの書き方](../reference/writing/writing_robust_scenarios_ja.md)

次へ: [テストを実行する](running_tests_ja.md)

### Link
- [index](../index_ja.md)
