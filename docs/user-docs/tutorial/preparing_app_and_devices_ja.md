# デバイスを用意する

[in English](preparing_app_and_devices.md)

クイックスタートで用意したデバイスを増やします。

## 1. 仮想デバイスを増やす

### AIへの指示文

```text
fleetest のテストプロジェクト project1 の実行プロファイル ios-run に、iPhone の Simulator をあと1台追加して。
使える Simulator が無ければ、同じ機種・同じ OS で作成してよい。
追加したら、実行プロファイルのデバイス一覧を報告して。
```

増やして Mac が重くなったら、減らすよう指示します。

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

デバイスモニターの「プロファイル」タブで、実行プロファイルの「デバイスを追加」を押します。

</details>
<br>

見えるもの: AIアシスタントが `ios-run` のデバイス一覧(1台増えたもの)を報告し、デバイスモニターの「プロファイル」タブにも並びます。

設定できる項目: [プロファイル](../reference/project/profiles_ja.md)・[実行プロファイルの設定項目](../reference/project/run_profile_ja.md)

次へ: [サーバーを確かめる](preparing_app_server_ja.md)

### Link
- [index](../index_ja.md)
