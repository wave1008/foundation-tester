# テストプロジェクトの作成

[in English](creating_project.md)

テストプロジェクト(`TestProjects/<name>/`)は、1つのアプリに対するシナリオ・プロファイル・
レポートをまとめる器です。このページではプロジェクトの構成と、それを管理するコマンドを説明します。

## 構成

```
TestProjects/SampleApp/
├── profiles/
│   ├── apps/ios-app.json          # アプリプロファイル(/fleetest-profiles = `profile setup` が作る。create 直後は無い)
│   └── runs/ios-run.json          # 実行プロファイル(`profile setup` が作る。アプリ+各自マシンを名乗るデバイス一覧+実行時設定)
├── scenarios/                     # Swift DSL
│   ├── _Main.swift                # ランナーへの委譲(編集不要)
│   ├── Generated/                 # ライブ操作の録画が生成したシナリオ
│   └── _disabled/                 # コンパイル対象外の退避場所(生成失敗コードの隔離先など)
├── reports/                       # シナリオごとの Markdown レポート
├── results/                       # 実行結果の JSON データベース(results_analysis_ja.md 参照)
└── .fleetest/                      # ロケータの指紋等(プロジェクト別の状態)
```

プロジェクトごとに SPM ターゲット `fleetest-scenarios-<name>` が対応するため、あるプロジェクトの
コンパイルエラーが他のプロジェクトを止めません。`_Main.swift` はターゲットとシナリオランナーを
つなぐだけのファイルで、通常は編集不要です。

## 2つのパッケージ構成

このプロジェクトの `Package.swift` が foundation-tester を参照する形には2種類あります。

- **外部パッケージ構成**(`/fleetest-setup` の既定): 作業フォルダ自身が
  foundation-tester のクローンに SPM 経由で依存する `Package.swift` を持ちます(`fleetest init`)。
  `TestProjects/` の資産は作業フォルダ側にあり、ツールのクローンとは分かれているため、
  ツールの更新がシナリオやプロファイルに触れることはありません。
- **クローン構成**: foundation-tester のクローンの中で直接作業し、`TestProjects/` もその中に
  置かれます。主にツール本体の開発時に使う構成です。

`fleetest init` は外部パッケージ構成(`Package.swift` + 最初のテストプロジェクト)を生成します。
`--no-project` を付けるとプロジェクトは作らず、`Package.swift` と空の `TestProjects/` だけを置きます
(インストールはこちらを使い、`project1` プロジェクトは後から `/fleetest-profiles` か VSCode 拡張が作ります。
`--no-project` は `--name` / `--app-id` と併用できません)。
`--fleetest-path` はローカルのクローンを指定し(`.package(path:)`)、`--fleetest-url` は代わりに
git URL へ依存させます(`--fleetest-branch` で追従するブランチを指定。既定は `main`)。

## プロジェクトの管理

| コマンド | 説明 |
|---|---|
| `fleetest project create <name>` | 新しいテストプロジェクトを作成し `Package.swift` に登録する(プロファイルは書かない。`/fleetest-profiles` で作る) |
| `fleetest project list` | テストプロジェクトの一覧と `Package.swift` への登録有無を表示する |
| `fleetest project sync` | `TestProjects/` を走査して `Package.swift` のマーカー区間を再生成する(手動コピーや `git pull` の後に実行する) |
| `fleetest project copy <source> <newName>` | プロジェクトを新しい名前で複製し `Package.swift` に登録する。実行の産物とキャッシュ(`reports/`・`results/`・`.fleetest/`)は複製されないので、複製先はまっさらな状態から始まる |
| `fleetest project rename <oldName> <newName>` | プロジェクトのディレクトリを改名し `Package.swift` を更新する |
| `fleetest project delete <name> --yes` | プロジェクトのディレクトリをゴミ箱へ移し(完全削除ではない)`Package.swift` から除く。`--yes` は必須 —— 付けなければ何も削除されない |

`Package.swift` のマーカー区間(`// === fleetest projects begin/end ===` の間)は
`create`/`sync` が全置換で再生成するので、手で編集しないでください。

## シナリオで使う依存を足す

シナリオからは Foundation などのシステムのモジュールと `FTDSL` をそのまま import できます。
それ以外の Swift パッケージや、複数のプロジェクトで共有する自前のターゲットを使うときは、
`Package.swift` の2箇所に書きます。

1. パッケージ自体を `Package` の `dependencies:` に足す(SwiftPM の通常の書き方)
2. 使うプロジェクトの名前をキーにして、`fleetestScenarioDependencies` に依存を足す

```swift
let fleetestScenarioDependencies: [String: [Target.Dependency]] = [
    "myapp": [
        .product(name: "SwiftOTP", package: "SwiftOTP"),
        "SharedHelpers",                 // 同じ Package.swift で定義した自前のターゲット
    ],
]

let package = Package(
    ...
    dependencies: [
        .package(path: "../foundation-tester"),
        .package(url: "https://github.com/<owner>/SwiftOTP", from: "<version>"),
    ],
    ...
```

`fleetestScenarioDependencies` はマーカー区間の外にあるので、`create`/`sync` は書き換えません
(宣言が無い `Package.swift` には `sync` が空の宣言を足します)。キーがプロジェクト名と一致しないと
その依存は使われないため、`sync` が警告を出します。

足した依存のビルド(マクロやビルドプラグインを含む)は、シナリオのサンドボックスの外で動きます。
信頼できるパッケージだけを足してください。

## プロジェクト名の制約

プロジェクト名は SPM ターゲット名になるため `^[A-Za-z0-9_][A-Za-z0-9_-]*$` に従う必要があります
(日本語不可)。この制約はプロジェクト名だけのもので、シナリオ内の `@TestClass` のクラス名は
このドキュメント全体の例のように日本語で構いません。

## `--project` の解決

多くのコマンドは `--project <name>` を受け付けます。省略時は次の順で解決されます。

1. `TestProjects/` にプロジェクトが1つだけならそれを使う
2. それ以外なら、設定済みのデフォルトプロジェクトを使う
3. それも無ければ、`project1` という名前のプロジェクトがあればそれを使う
4. どれも無ければ、候補一覧付きのエラーで停止する

## `project1` プロジェクト

VSCode 拡張は起動時に `TestProjects/project1/` が無ければ(または空なら)`fleetest project create project1`
で作成し、`fleetest.project` が空のときはこの `project1` を初期選択にします。すぐにシナリオを置ける器として
使えます(シナリオもプロファイルもまだ無いので、プロファイルは `/fleetest-profiles` か `fleetest profile setup` で作ってください)。
別の名前で作ったプロジェクトを使うときは、拡張の「プロジェクトを選択」か `fleetest.project` で切り替えます。

### Link
- [index](../../index_ja.md)
