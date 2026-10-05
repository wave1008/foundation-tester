module.exports = {
  presets: ['module:@react-native/babel-preset'],
  // react-native-reanimated v4 は worklet 変換を react-native-worklets に委譲している。
  // このプラグインは配列の最後に置く(公式ドキュメントの要件)。
  plugins: ['react-native-worklets/plugin'],
};
