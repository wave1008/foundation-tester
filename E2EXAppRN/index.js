/**
 * react-native-gesture-handler は必ずエントリポイントの先頭で import する(公式要件。
 * 他の import より後だと Android でネイティブビューの登録が間に合わないことがある)。
 *
 * @format
 */
import 'react-native-gesture-handler';

import { AppRegistry } from 'react-native';
import App from './App';
import { name as appName } from './app.json';

AppRegistry.registerComponent(appName, () => App);
