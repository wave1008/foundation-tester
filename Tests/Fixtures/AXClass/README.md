# XCUITest の `axClass`(要素のクラス名)の固定コーパス

`GET /snapshot` の生 JSON(2026-09-12・iOS 27.0 Simulator `iPhone 17 Pro(iOS 27.0)`・XCUITest ランナー版 99)。
`ElementInfo.axClass` は XCTest の**非公開属性 5004** から採るので、Xcode の版で値や辞書が変わりうる。
`AXClassFixtureTests` が各フレームワークの値を等号で固定し、空打ちの第3段(`AccessibilityClassHint`)の判定が
このコーパスで変わらないことを守る。**Xcode を上げて落ちたら**、新しい値で `AccessibilityClassHint` の規則を
見直してから貼り替える(取れなくなった場合は nil = 撃たない側へ縮退する設計がそのまま効く)。

| ファイル | 由来 | 対話要素のクラス名 |
|---|---|---|
| `xcui-cmp` | E2E-CMP(Compose Multiplatform)ホーム | `UIAccessibilityElement` |
| `xcui-flutter` | E2E-Flutter ホーム | `UIAccessibilityElement` |
| `xcui-rn` | E2E-RN(React Native)ホーム | `UIView` |
| `xcui-ios` | E2E-iOS(SwiftUI)ホーム | `NSObject` |
| `xcui-Preferences` | iOS 設定(UIKit + SwiftUI) | `NSObject` / `UICollectionViewListCell` 系 |
| `xcui-Maps` | Apple マップ(UIKit。`UIAccessibilityElement` が少数出る実アプリの witness) | `UIButton` / `NSObject` / `UIAccessibilityElement` ×6 |
