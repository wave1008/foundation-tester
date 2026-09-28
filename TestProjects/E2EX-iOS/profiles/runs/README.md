# profiles/runs

実行プロファイル(ファイル名 = プロファイル名)。使うアプリ(`app` = apps/ のファイル名)と、
走らせるデバイスの実体(`devices`)と、実行時の設定を持つ。

`devices` の1要素:
- `platform`(必須): `"ios"` / `"android"`
- `machine`: **そのデバイスがある機械**(ホスト名ではなく `fleetest remote machines` の
  マシン名 = このマシンだけのエイリアス)。手元は `"local"`(ツールは常に明示して書く)。
  書けるのはマシン名だけ(ssh の宛先は書けない)
- `name`(必須): デバイスの名前。**一意なのは (machine, name)** なので、別の機械に同名の
  デバイスが居てよく、1つの実行プロファイルで手元とリモートを同時に回せる
- `enabled`: `false` なら一覧に残すが走らせない(拡張のチェックボックス)。省略 = 走らせる
- 実体: iOS シミュレータは `name` をシミュレータ自身の名前(Xcode の Name)にし、`os`(OS Version)・
  `udid`・`model`(Model。表示専用)を書く。Android は `avd` / 実機なら `kind: "physical"` と `serial`

**同じデバイスは複数の実行プロファイルに載る**。拡張で名前などを直すと、同じ
(platform, machine, name) を持つ全ての実行プロファイルへ反映される。手で直すときは全部を揃える。
Android の `avd` は AVD の ID("Pixel_9_Android_16")と表示名("Pixel 9(Android 16)")の
どちらでも書ける。iOS の `os`(例 `"26.0"`)は任意で、**書かなければ名前一致の最新ランタイム**に
解決される(このマシンに無い版を書くと解決不能になる)。

```json
{
  "app": "myapp",
  "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
    { "platform": "android", "machine": "local", "name": "emulator1", "avd": "Pixel 9(Android 16)" },
    { "platform": "android", "machine": "local", "name": "emulator2", "enabled": false, "avd": "Pixel_8_Android_14" }
  ],
  "heal": true
}
```