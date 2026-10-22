# アプリとデバイスを用意する

[in English](preparing_app_and_devices.md)

自分のアプリと、テストに使うデバイスを fleetest に登録します。

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

見えるもの: AIアシスタントが実行プロファイル名(`ios-run` など)を報告します。VSCode では、コマンドパレットの
`fleetest: プロジェクトを選択` で `myshop` に切り替えると、デバイスモニターの「プロファイル」タブに並びます。

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

## 2. デバイスを増やす

### AIへの指示文

```text
fleetest のテストプロジェクト myshop の実行プロファイル ios-run に、iPhone の Simulator をあと2台追加して。
使える Simulator が無ければ、同じ機種・同じ OS で作成してよい。
追加したら、実行プロファイルのデバイス一覧を報告して。
```

増やして Mac が重くなったら、減らすよう指示します。

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

デバイスモニターの「プロファイル」タブで、実行プロファイルの「デバイスを追加」を押します。

</details>

## 3. 実機を使う(任意)

先に端末の自動ロックを切ってください(画面が消えると fleetest は端末を起こせません)。

### AIへの指示文

```text
USB でつないだ iPhone 15 を、fleetest のテストプロジェクト myshop に新しい実行プロファイル ios-physical として登録して。
アプリは既存のアプリプロファイルのものを使い、実機向けのビルドには ~/builds/MyShop.ipa を使って。
登録したら、実行プロファイルの名前と、端末が認識されたかどうかを報告して。
```

端末側の準備(デベロッパモード・USB デバッグなど)は[実機を追加する](../fleet/adding_physical_devices_ja.md)にあります。

## アプリを作り直したとき

パスが同じなら何もしなくて構いません(実行のたびに、変わっていれば入れ直します)。パスが変わったときだけ指示します。

```text
fleetest のテストプロジェクト myshop のアプリプロファイルにある iOS のアプリのパスを、~/builds/MyShop-2.0.app に変えて。
```

設定できる項目: [プロファイル](../reference/project/profiles_ja.md)・[実行プロファイルの設定項目](../reference/project/run_profile_ja.md)

次へ: [アプリが依存するサーバーを用意する](preparing_app_server_ja.md)

### Link
- [index](../index_ja.md)
