# ft_e2ey_rn

fleetest の E2E テスト対象アプリ(SUT)。React Native 0.86(New Architecture 有効) + TypeScript。
実アプリで頻出する画面の作り(ホーム + 12 画面 A1〜A12)を React Native の定番ライブラリ
(react-navigation・reanimated・gesture-handler・gorhom bottom-sheet・flash-list・react-native-collapsible-tab-view)で並べる。

UI 契約(`#id`・ラベル・画面構成)の唯一の正は `E2EYAppCMP/docs/ui-contract.md`。
React Native 実装固有の差分は `docs/ui-contract.md`(このディレクトリ)にある。

## ビルド

```sh
npm ci
cd ios && pod install && cd ..
scripts/build-ios.sh      # dist/ios-simulator/FTE2EYRN.app (Release)
scripts/build-android.sh  # dist/android/ft-e2ey-rn-release.apk (Release)
```
