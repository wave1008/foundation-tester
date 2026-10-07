# アプリとデバイスを用意する

[in English](preparing_app_and_devices.md)

テストを動かすには、**何を**(テスト対象のアプリ)**どこで**(デバイス)動かすかを fleetest に登録します。
登録の中身は2種類のプロファイルです。

| プロファイル | 決めること |
|---|---|
| アプリプロファイル | アプリの表示名・アプリ ID・ビルド済みアプリのパス |
| 実行プロファイル | どのアプリを、どのデバイスで、どんな設定で動かすか |

どちらも AIアシスタントに頼めば作れます。JSON を手で書く必要はありません。

## 最初の登録

### AIへの指示文

```text
自分のアプリ向けに、fleetest のプロファイルを作成して。
アプリの表示名は「My Shop」。アプリ ID は iOS が com.example.myshop、Android が com.example.myshop.android。
ビルド済みのアプリは ~/builds/MyShop.app(iOS Simulator 向け)と ~/builds/myshop-debug.apk にある。
デバイスには、この Mac で使える最新 OS の Simulator / Emulator を選んで。
作成した実行プロファイルの名前を報告したら終わりにして。テストは実行しなくてよい。
```

- **表示名**は、ホーム画面でアイコンの下に出る名前そのものにします(「(テスト用)」などの注記を足さない)。
  fleetest はこの名前でホーム画面のアイコンを探し、システムのダイアログがどのアプリのものかを見分けます。
- **ビルド済みのアプリのパス**を渡すと、テストの実行時にデバイスへ自動でインストールされます。
  iOS Simulator には `.app`、Android には `.apk` を渡します。
  Simulator 向けの `.app` の作り方は[クイックスタート](../quick-start_ja.md)の手動手順の `xcodebuild` の例を参考にしてください。
  AIアシスタントに「このプロジェクトを Simulator 向けにビルドして」と頼むこともできます。
- iOS だけ・Android だけのアプリなら、片方だけ書けば足ります。

Claude Code では `/fleetest-profiles` でも同じことができます(アプリ名などを順に質問されます)。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest profile setup --platform ios --app-id com.example.myshop --auto-device \
  --app-path ~/builds/MyShop.app
../foundation-tester/.build/debug/fleetest profile setup --platform android --app-id com.example.myshop.android --auto-device \
  --app-path ~/builds/myshop-debug.apk
../foundation-tester/.build/debug/fleetest profile list
```

VSCode 拡張のデバイスモニターの「プロファイル」タブからも作成・編集できます。

</details>

## デバイスを増やす

デバイスを増やすと、テストが複数のデバイスへ自動で振り分けられ、全体の時間が短くなります
(シナリオを書き換える必要はありません)。

### AIへの指示文

```text
fleetest の実行プロファイル ios-run に、iPhone の Simulator をあと2台追加して。
使える Simulator が無ければ、同じ機種・同じ OS で作成してよい。
追加したら、実行プロファイルのデバイス一覧を報告して。
```

同時に動かせる台数は Mac のメモリと CPU で決まります。増やして遅くなったら、減らすよう頼んでください。

<details>
<summary><b>手動で実行(クリックで詳細表示)</b></summary>

VSCode 拡張のデバイスモニターの「プロファイル」タブで、実行プロファイルの「デバイスを追加」を使うか、
デバイス一覧のチェックボックスで使うデバイスを選びます。

</details>

## 実機(本物の iPhone / Android)を使う

USB でつないだ実機もテストに使えます。**先に端末側で自動ロックを切ってください**
(iOS: 設定 → 画面表示と明るさ → 自動ロック → なし。Android: 設定 → ディスプレイ → 画面消灯を十分長く)。
fleetest は画面の消えた端末を起こせません。

### AIへの指示文

```text
USB でつないだ iPhone を、fleetest の新しい実行プロファイル ios-physical として登録して。
アプリは既存のアプリプロファイルのものを使い、実機向けのビルドには ~/builds/MyShop.ipa を使って。
登録したら、実行プロファイルの名前と、端末が認識されたかどうかを報告して。
```

実機を複数つないでいるときは、どの端末かを機種名で添えてください(「USB でつないだ iPhone 15 を…」)。
添えないと、AIアシスタントはどれを登録するか決められずに質問で止まります。

iOS の実機向けアプリは署名済みのもの(`.ipa` または `.app`)が要ります。
端末側の準備(デベロッパモード・USB デバッグなど)と、別の Mac につないだ実機の使い方は[実機を追加する](../fleet/adding_physical_devices_ja.md)にあります。

## アプリを作り直したとき

アプリのパスが同じなら、何もしなくて構いません。実行のたびに、デバイスに入っているアプリと
パスのアプリを比べ、違っていればインストールし直します。パスやファイル名が変わったときだけ、
登録を直すよう頼みます。

```text
fleetest のアプリプロファイルにある iOS のアプリのパスを、~/builds/MyShop-2.0.app に変えて。
```

## もっと詳しく

- 設定できる項目の一覧: [プロファイル](../reference/project/profiles_ja.md)・[実行プロファイルの設定項目](../reference/project/run_profile_ja.md)
- テストプロジェクト(テストをまとめる単位)を分けたいとき: [テストプロジェクトの作成](../reference/project/creating_project_ja.md)

次へ: [テストを作る](creating_tests_ja.md)

### Link
- [index](../index_ja.md)
