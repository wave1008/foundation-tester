---
paths:
  - "Sources/FTCore/DeviceFrozen*.swift"
  - "Sources/FTCore/DeviceFrozenStore.swift"
  - "Sources/FTCore/Frozen*.swift"
  - "Sources/FTCore/FrozenVerdict.swift"
  - "Tests/FTCoreTests/DeviceFrozenStoreTests.swift"
  - "Tests/FTCoreTests/FrozenVerdictTests.swift"
---

# デバイスの健康状態(凍結) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **デバイスの健康状態も同じ**: 「画面が凍結しているか」は `FTCore.FrozenVerdict` が唯一の定義元で、
  run 前トリアージとモニターは**根拠(`FrozenEvidence`)を束ねた同じ型**を配る。プロセスを跨ぐ
  受け渡しは `FTCore.DeviceFrozenStore`(`.fleetest/frozen-<key>.json`。RunLease と同じ
  pid 生存 + mtime)。**新しい根拠は `isConclusive=false`(警告)から入れる**
