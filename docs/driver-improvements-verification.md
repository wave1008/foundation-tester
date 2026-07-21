# ドライバ改良の効果検証レポート(main マージ後)

実施日: 2026-07-21 / 対象: main(PR #1 マージ後の HEAD)

## 目的

Appium 比較 PoC 由来のドライバ改良(PR #1)が main 上で期待どおりの効果を出しているかを、
マージ後のバイナリで再計測して確認する。

## 計測条件

- 専用シミュレータ iPhone 17 Pro(iOS 27.0 / 24A5390f)を新規作成・単独使用
  (フリート6台は起動中だがアイドル。負荷は全系統に等しく乗る)
- シナリオ4本(タブナビ25step・カート追加15step・検索絞り込み8step・ログイン3テスト29step)
- 各系統 warmup 1 + 計測 2。計測は wall(ハーネス側)と step NDJSON(FT_EVENT_LOG_PATH)
- **全36ラン失敗ゼロ**・計測ばらつき ±0.3s 以内
- 改良オフ側は `FT_NO_FAST_LAUNCH=1`(fast launch 無効)で同一バイナリ内 A/B

## 結果1: シナリオ全体(wall 中央値・秒)

| シナリオ | hybrid(in-app) | xcuitest(改良on=既定) | xcuitest(改良off) | 改良効果 |
|---|---|---|---|---|
| タブナビ | 7.5 | **11.5** | 13.3 | **−14%** |
| カート追加 | 7.2 | **9.6** | 11.3 | **−15%** |
| 検索絞り込み | 4.5 | **6.8** | 8.6 | **−21%** |
| ログイン(launch×3) | 15.2 | **23.5** | 28.6 | **−18%** |

- xcuitest の改良効果(fast launch)は同一バイナリ A/B で **−14〜21%** を再現
- hybrid のログイン 15.2s は改良前ベースライン(bench-6: 18.9s)比 **−20%**
  (inapp type の Compose 対応の効果。同一ランタイム・専用シミュレータ条件)

## 結果2: 操作単位(step 中央値・ms)

| 操作 | hybrid | xcuitest(改良on) | xcuitest(改良off) |
|---|---|---|---|
| launch(アプリ再起動) | 2,480 | **3,467** | 5,208(fast launch で −33%) |
| type | **266**(in-app 直接挿入) | 1,176 | 1,172 |
| tap | 126 | 406 | 416 |
| exist | 6 | 36 | 36 |

- **hybrid の type 266ms** = inapp の Compose 対応が main で機能している実証
  (従来は XCUITest attach 経由で 1.0〜1.3s だった)
- tap/exist は改良対象外のため on/off で一致(計測系の公平性の傍証)

## 判定

**マージされた改良は main 上で期待どおり機能・効果を再現している。**

| 改良項目 | 期待(改良ブランチでの実測) | 検証結果 |
|---|---|---|
| fast launch 既定化 | シナリオ −14〜19% | ✅ −14〜21% |
| inapp type の Compose 対応 | ログイン系 −19%・type 約1/4 | ✅ −20%・266ms |
| 安定性 | 失敗ゼロ | ✅ 36/36 成功 |

## 再現手順

```bash
# 専用シミュレータ+verify プロファイル(machines/LDIPC96-verify 等)を用意して
FT_EVENT_LOG_PATH=<file> ftester run --project sut-ec-mobile \
  --profile <ios-verify-xcuitest|ios-verify-hybrid> --scenario <シナリオ> --skip-build
# 改良オフ側: FT_NO_FAST_LAUNCH=1 を前置
```

計測口の詳細は performance-tuning.md §4、改良の経緯・不採用判断は同 §6/§7 と
`poc/appium-driver-benchmark` ブランチの docs/poc-appium-benchmark.md を参照。
