---
paths:
  - "Runner/FleetestRunnerUITests/FastInput.swift"
  - "Tests/FTCoreTests/ProfileResolver*.swift"
  - "Sources/FTCore/RunProfile*.swift"
  - "Sources/FTCore/RunProfile.swift"
  - "Sources/fleetest/ApiRunCommand.swift"
  - "Sources/fleetest/Fleetest.swift"
  - "Tests/FTCoreTests/ProfileResolverTests.swift"
  - "Tests/FTCoreTests/ResolvedProfileDeviceLimitTests.swift"
  - "Tests/FleetestTests/ResolvedProfileDeviceScopeTests.swift"
---

# 実行プロファイルの --set の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **実行プロファイルのキーは `--set <キー>=<値>` の1つの口で上書きする**(ユーザー決定 2026-09-08)。
  **キー名はプロファイル JSON・拡張のチェックボックスと1文字も同じ**(kebab 変換をしない)。
  受けるのは `RunProfileDocument` の Bool とスカラー(String/Int/Double)で、配列・オブジェクト
  (`devices`/`remoteControl`)は専用のメッセージで断る(「未知のキー」に丸めない)。
  **キーごとに専用フラグを生やさない** —— 以前は 20 個のチェックボックスに対し CLI が4個・
  形も3通り(両方向/否定のみ/肯定のみ)で、`iosFastInput`→`--fast-input` とキー名すら
  ずれていた。**同じ非対称が育たないよう2つで守る**: ①**上書きは
  `ProfileResolver.resolve` が読み込み直後の文書へ当てる1箇所だけ**(消費側へ個別配線しない。
  `ResolvedProfile` の全欄が自動で追随する)②**`--set` が受けるキーの集合 ==
  `RunProfileDocument` の全欄**(配列・オブジェクトを除く)を `Mirror` で
  等号固定(`RunProfileSetOverrideTests`)—— 新しい欄を足して `--set` から漏れると落ちる。
  **同じ意味の専用フラグ(`--report-dir` / `--default-timeout` / `--scenario-timeout`)と
  併用したらエラー**(片方を黙って勝たせない)。**`--app-id` / `--runner` は衝突させない** ——
  CLI のそれらは「既定アプリの bundle ID」「リモートディスパッチ先」で、プロファイルのキー
  `app`(アプリプロファイル名)・`devices[].machine`(デバイスが居るマシン名)とは**別物**。
  **`--profile` を要求してよいのは、プロファイルの devices 一覧・供給工程が要るキーだけ**
  (`profileOnlyKeys`)—— 「配線が無いだけ」のキーをここへ入れない(実際 `record` 系と
  `homeOnStart` は配線するだけで profile-less でも動いた)。**指定したのに黙って効かない形を
  作らない** = 効かせられないなら名指しでエラーにする。経緯は maintainer-notes §16
