# テスト対象アプリを用意する

[in English](preparing_app.md)

自分のアプリを fleetest に登録します。サンプルアプリ(SUT Store)の `project1` とは別の、新しいテストプロジェクトに入れます
(`project1` に入れると、サンプルの登録が上書きされます)。

## 1. アプリを登録する

### AIへの指示文

```text
fleetest のテストプロジェクト myshop を新しく作り、自分のアプリを登録して。
アプリの表示名は「My Shop」。アプリ ID は iOS が com.example.myshop、Android が com.example.myshop.android。
アプリのソースは ~/src/myshop にある。iOS Simulator 向けと Android Emulator 向けにビルドして使って
(React Native のアプリなら Release 構成でビルドして)。
デバイスには、この Mac で使える最新 OS の Simulator / Emulator を選んで。
作成した実行プロファイルの名前を報告したら終わりにして。テストは実行しなくてよい。
```

- 表示名は、ホーム画面でアイコンの下に出る名前そのままにします。
- ビルド済みのアプリがあるなら、ソースの代わりにそのパス(`.app` / `.apk`)を伝えます。
- 以降の指示にも、テストプロジェクト名(`myshop`)を添えます。

期待する結果:

- AIアシスタントが実行プロファイル名(`ios-run` など)を報告します。
- VSCode では、コマンドパレットの `fleetest: プロジェクトを選択` で `myshop` に切り替えると、デバイスモニターの「プロファイル」タブに並びます。

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

アプリをビルドしてから(iOS Simulator 向けの `xcodebuild` の例は[クイックスタート](../quick-start_ja.md)。
React Native は Release 構成)、作業フォルダで実行します。

```bash
../foundation-tester/.build/debug/fleetest project create myshop
../foundation-tester/.build/debug/fleetest profile setup --project myshop --platform ios --app-id com.example.myshop \
  --app-name "My Shop" --auto-device --app-path ~/builds/MyShop.app
../foundation-tester/.build/debug/fleetest profile setup --project myshop --platform android --app-id com.example.myshop.android \
  --app-name "My Shop" --auto-device --app-path ~/builds/myshop-debug.apk
```

</details>

## 2. アプリを作り直したとき

アプリを作り直しても、パスが同じなら何もしなくて構いません(実行のたびに、アプリが変わっていれば入れ直します)。
パスやファイル名が変わったときだけ指示します。

### AIへの指示文

```text
fleetest のテストプロジェクト myshop のアプリプロファイルにある iOS のアプリのパスを、~/builds/MyShop-2.0.app に変えて。
```

設定できる項目:

- [プロファイル](../reference/project/profiles_ja.md)
- [実行プロファイルの設定項目](../reference/project/run_profile_ja.md)

次へ: [アプリが依存するサーバーを用意する](preparing_server_ja.md)

### Link
- [index](../index_ja.md)
