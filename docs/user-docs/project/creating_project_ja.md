# テストプロジェクトの作成

テストプロジェクト(`TestProjects/<name>/`)は、1つのアプリに対するシナリオ・プロファイル・
レポートをまとめる器です。このページではプロジェクトの構成と、それを管理するコマンドを説明します。

## 構成

```
TestProjects/SampleApp/
├── profiles/
│   ├── apps/sampleapp_ios.json    # アプリプロファイル
│   ├── machines/M2Ultra.json      # マシン別デバイス定義(ファイル名 = マシン名)
│   └── runs/ios.json              # 実行プロファイル(アプリ+デバイス名リスト+実行時設定)
├── scenarios/                     # Swift DSL
│   ├── _Main.swift                # ランナーへの委譲(編集不要)
│   ├── Generated/                 # ライブ操作の録画が生成したシナリオ
│   └── _disabled/                 # コンパイル対象外の退避場所(生成失敗コードの隔離先など)
├── reports/                       # シナリオごとの Markdown レポート
├── results/                       # 実行結果の JSON データベース(results_analysis_ja.md 参照)
└── .fleetest/                      # ヒールキャッシュ等(プロジェクト別の状態)
```

プロジェクトごとに SPM ターゲット `fleetest-scenarios-<name>` が対応するため、あるプロジェクトの
コンパイルエラーが他のプロジェクトを止めません。`_Main.swift` はターゲットとシナリオランナーを
つなぐだけのファイルで、通常は編集不要です。

## 2つのパッケージ構成

このプロジェクトの `Package.swift` が foundation-tester を参照する形には2種類あります。

- **外部パッケージ構成**(`/fleetest:fleetest-setup` の既定): 作業フォルダ自身が
  foundation-tester のクローンに SPM 経由で依存する `Package.swift` を持ちます(`fleetest init`)。
  `TestProjects/` の資産は作業フォルダ側にあり、ツールのクローンとは分かれているため、
  ツールの更新がシナリオやプロファイルに触れることはありません。
- **クローン構成**: foundation-tester のクローンの中で直接作業し、`TestProjects/` もその中に
  置かれます。主にツール本体の開発時に使う構成です。

`fleetest init` は外部パッケージ構成(`Package.swift` + 最初のテストプロジェクト)を生成します。
`--fleetest-path` はローカルのクローンを指定し(`.package(path:)`)、`--fleetest-url` は代わりに
git URL へ依存させます(`--fleetest-version` は最小版を固定するタグ、`--fleetest-branch` はタグが
無い間の検証用にブランチを追従します)。

## プロジェクトの管理

| コマンド | 説明 |
|---|---|
| `fleetest project create <name> [--app <bundleID>] [--platform ios\|android\|both]` | 新しいテストプロジェクトを作成し `Package.swift` に登録する |
| `fleetest project list` | テストプロジェクトの一覧と `Package.swift` への登録有無を表示する |
| `fleetest project sync` | `TestProjects/` を走査して `Package.swift` のマーカー区間を再生成する(手動コピーや `git pull` の後に実行する) |

`Package.swift` のマーカー区間(`// === fleetest projects begin/end ===` の間)は
`create`/`sync` が全置換で再生成するので、手で編集しないでください。

## プロジェクト名の制約

プロジェクト名は SPM ターゲット名になるため `^[A-Za-z0-9_][A-Za-z0-9_-]*$` に従う必要があります
(日本語不可)。この制約はプロジェクト名だけのもので、シナリオ内の `@TestClass` のクラス名は
このドキュメント全体の例のように日本語で構いません。

## `--project` の解決

多くのコマンドは `--project <name>` を受け付けます。省略時は次の順で解決されます。

1. `TestProjects/` にプロジェクトが1つだけならそれを使う
2. それ以外なら、設定済みのデフォルトプロジェクトを使う
3. どちらも無ければ、候補一覧付きのエラーで停止する

### Link
- [index](../index_ja.md)
