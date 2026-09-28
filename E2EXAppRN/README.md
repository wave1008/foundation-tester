# ft_e2ex_rn

fleetest の E2E テスト対象アプリ(SUT)。React Native 0.86(New Architecture 有効) + TypeScript。
`E2EAppRN` とは別の SUT で、共通契約の画面は持たない —— React Native の**定番ライブラリ**
(react-navigation・reanimated・gesture-handler・bottom-sheet・paper 等)を
`E2EXAppCMP`(Compose Multiplatform)と同じ 15 画面構成で並べ、部品ごとの癖を拾う。

UI 契約(`#id`・ラベル・画面構成)の唯一の正は `E2EXAppCMP/docs/ui-contract.md`。
React Native 実装固有の差分は `docs/ui-contract.md`(このディレクトリ)にある。

## ビルド

```sh
npm install
cd ios && bundle exec pod install && cd ..
scripts/build-ios.sh      # dist/ios-simulator/FTE2EXRN.app (Release)
scripts/build-android.sh  # dist/android/ft-e2ex-rn-release.apk (Release)
```
