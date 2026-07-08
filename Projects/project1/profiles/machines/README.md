# profiles/machines

マシンプロファイル(ファイル名 = マシン名。例: `M1 Max(64GB).json`)。
このマシンで使えるデバイスを ios / android セクションに `name` 付きで列挙する。
実行プロファイル(runs/)はデバイスを `name` で参照するため、name は ios/android 横断で一意にすること。

実行時のマシン選択: FT_MACHINE 環境変数 > `ftester machine set` の登録名 >
ここに .json が 1 つだけならそれを自動採用。

```json
{
  "ios": {
    "devices": [
      { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" },
      { "name": "サブ機", "simulator": "iPhone Air", "udid": "XXXX-XXXX" }
    ]
  },
  "android": {
    "devices": [
      { "name": "エミュ1", "avd": "Pixel_9" },
      { "name": "エミュ2", "serial": "emulator-5556" }
    ]
  }
}
```