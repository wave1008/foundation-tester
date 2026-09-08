# profiles/machines

マシンプロファイル(ファイル名 = マシン名。例: `M2 Ultra(192GB).json`)。
このマシンで使えるデバイスを ios / android セクションに `name` 付きで列挙する。
実行プロファイル(runs/)はデバイスを `name` で参照するため、name は ios/android 横断で一意にすること。
Android の `avd` は AVD の ID("Pixel_9_Android_16")と表示名("Pixel 9(Android 16)")の
どちらでも書ける。

実行時のマシン選択: 実行プロファイルの `machine` > FT_MACHINE 環境変数 >
ここに .json が 1 つだけならそれを自動採用。

`"machine"` は**そのデバイスがある機械**(ホスト名ではなく `fleetest remote machines` の
マシン名 = このマシンだけのエイリアス)。**手元でも省略せず `"local"` と書く**(省略は
「直下の既定を継ぐ」の意味になり、既定がリモートのときに別の機械のデバイス扱いになる)。
ツールが書き出すときは常に `machine` → `name` の順で先頭に置く。
別の Mac(リモートランナー)を指すときも書けるのはマシン名だけ(ssh の宛先は書けない)。
`machine` を書いておくと `--runner` を付けなくてもその機械へディスパッチされる。
**トップレベルにも devices の各要素にも書ける** —— トップレベルは既定で、デバイス側が優先。
**一意なのは (machine, name)** なので、別の機械に同名のデバイスが居てよく、
1つの実行プロファイルで手元とリモートを同時に回せる(docs/remote-runner-setup.md)。
**旧キー `"host"` のプロファイルもそのまま読める**(2026-08-26 に改名)。

iOS の `os`(例 `"26.0"`)は任意。**書かなければ名前一致の最新ランタイム**に解決されるので、
複数ランタイムを使い分けるとき以外は省略する(このマシンに無い版を書くと解決不能になる)。

```json
{
  "ios": {
    "devices": [
      { "machine": "local", "name": "simulator1", "simulator": "iPhone 17 Pro" },
      { "machine": "local", "name": "simulator2", "simulator": "iPhone Air", "udid": "XXXX-XXXX" }
    ]
  },
  "android": {
    "devices": [
      { "machine": "local", "name": "emulator1", "avd": "Pixel 9(Android 16)" },
      { "machine": "local", "name": "emulator2", "avd": "Pixel_8_Android_14" }
    ]
  }
}
```