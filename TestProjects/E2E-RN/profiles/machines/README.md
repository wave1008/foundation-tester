# profiles/machines

マシンプロファイル(ファイル名 = マシン名。例: `M2 Ultra(192GB).json`)。
このマシンで使えるデバイスを ios / android セクションに `name` 付きで列挙する。
実行プロファイル(runs/)はデバイスを `name` で参照するため、name は ios/android 横断で一意にすること。
Android の `avd` は AVD の ID("Pixel_9_Android_16")と表示名("Pixel 9(Android 16)")の
どちらでも書ける。

実行時のマシン選択: FT_MACHINE 環境変数 > `fleetest machine set` の登録名 >
ここに .json が 1 つだけならそれを自動採用。

iOS の `os`(例 `"26.0"`)は任意。**書かなければ名前一致の最新ランタイム**に解決されるので、
複数ランタイムを使い分けるとき以外は省略する(このマシンに無い版を書くと解決不能になる)。

```json
{
  "ios": {
    "devices": [
      { "name": "simulator1", "simulator": "iPhone 17 Pro" },
      { "name": "simulator2", "simulator": "iPhone Air", "udid": "XXXX-XXXX" }
    ]
  },
  "android": {
    "devices": [
      { "name": "emulator1", "avd": "Pixel 9(Android 16)" },
      { "name": "emulator2", "avd": "Pixel_8_Android_14" }
    ]
  }
}
```