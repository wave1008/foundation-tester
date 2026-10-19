---
paths:
  - "Sources/FTCore/DeviceFrozen*.swift"
  - "Sources/FTCore/DeviceFrozenStore.swift"
  - "Sources/FTCore/Frozen*.swift"
  - "Sources/FTCore/FrozenVerdict.swift"
  - "Tests/FTCoreTests/DeviceFrozenStoreTests.swift"
  - "Tests/FTCoreTests/FrozenVerdictTests.swift"
  - "Sources/FTCore/DisplayFreezeDetector.swift"
  - "Sources/FTAndroid/DisplayFreezeWatch.swift"
  - "Tests/FTCoreTests/DisplayFreezeDetectorTests.swift"
  - "Tests/FTAndroidTests/DisplayFreezeWatchTests.swift"
  - "Sources/FTAndroid/AndroidHealthProbe.swift"
---

# デバイスの健康状態(凍結) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **デバイスの健康状態も同じ**: 「画面が凍結しているか」は `FTCore.FrozenVerdict` が唯一の定義元で、
  run 前トリアージとモニターは**根拠(`FrozenEvidence`)を束ねた同じ型**を配る。プロセスを跨ぐ
  受け渡しは `FTCore.DeviceFrozenStore`(`.fleetest/frozen-<key>.json`。RunLease と同じ
  pid 生存 + mtime)。**新しい根拠は `isConclusive=false`(警告)から入れる**
- **「表示が止まった」(一様でない凍結)は run の境目の `DisplayFreezeWatch` が見る**(判定は `FTCore.DisplayFreezeDetector`
  の 1 箇所 = 同じ絵が 60 秒以上・home で変わらない。docs/design.md の該当節)。**前回の境目の絵は run をまたいで引き継ぐ**
  (`DisplayFreezeWatch.Baseline`。run ごとの控えに戻すと、レーンあたりの本数が少ない run では凍結を永久に疑えない)。**疑いだけでデバイスを触らない**(確定は
  home の確認)・**実機は見ない**・確定したら `.frozen` と同じ経路(直前の結果を捨てて振り直し → 回復 → revive)。
  **プロセス内の `StaleFrameDetector` を凍結の根拠に流用しない**(通ったステップに大量に立つ注記で、精度が違う)。
  回復の段(sleep/wake → ゲストの再起動 → 停止と起動)を足す・変えるときは `WorkerRecoveryKind` と docs/results-json.md も

- **run の前の Android の点検は「凍結」と「ホストへの経路」の2段**(`excludeOrRepairBlankScreenWorkers` の1入口)。経路は
  `AndroidHealthProbe.hostRoute` の3値で、**不明は撃たない**。Emulator の停止と起動は `ProfileWorkerFactory.stopAndStartEmulator` の
  1箇所(DisplayFreezeWatch と共有)で、呼び手は撃つ前に持ち主を確かめる。点検の結果を run.json へ載せるのは `triage.anomalies`
  (除外の理由を台ごとに持つ。`PreRunTriageRecordWiringTests`)
