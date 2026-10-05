/**
 * FT E2EY RN — fleetest 用の SUT アプリ(実アプリで頻出する画面の作りの実験場)。
 * 画面構成・#id・ラベルの唯一の正は E2EYAppCMP/docs/ui-contract.md。
 * RN 実装固有の差分は docs/ui-contract.md(このディレクトリ)。
 *
 * @format
 */

import React from 'react';
import { StatusBar, Text, useColorScheme } from 'react-native';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { enableScreens } from 'react-native-screens';
import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';

import type { RootStackParamList } from './src/navigation';
import { HomeScreen } from './src/screens/HomeScreen';
import { NestedScreen } from './src/screens/NestedScreen';
import { ChatScreen } from './src/screens/ChatScreen';
import { LoadingScreen } from './src/screens/LoadingScreen';
import { SwipeActionsScreen } from './src/screens/SwipeActionsScreen';
import { SelectScreen } from './src/screens/SelectScreen';
import { LinksScreen } from './src/screens/LinksScreen';
import { PinScreen } from './src/screens/PinScreen';
import { BackGuardScreen, EditorScreen } from './src/screens/BackGuardScreen';
import { PlayerScreen } from './src/screens/PlayerScreen';
import { HideBarsScreen } from './src/screens/HideBarsScreen';
import { TabHeaderScreen } from './src/screens/TabHeaderScreen';
import { StaggeredScreen } from './src/screens/StaggeredScreen';

enableScreens();

const Stack = createNativeStackNavigator<RootStackParamList>();

function App() {
  const isDarkMode = useColorScheme() === 'dark';
  return (
    // GestureHandlerRootView はツリー全体を包む(gesture-handler の必須要件)。
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
        <NavigationContainer>
          <Stack.Navigator
            screenOptions={{
              headerTitle: props => <Text testID="txt_screen_title">{props.children}</Text>,
              // #btn_back は付けない: native-stack の戻るボタンはネイティブ描画で testID を通せない
              // (docs/ui-contract.md)。ラベルは出さずシェブロンだけにして 5 SUT の見た目差を縮める。
              headerBackButtonDisplayMode: 'minimal',
            }}
          >
            <Stack.Screen name="Home" component={HomeScreen} options={{ title: 'E2EY ホーム' }} />
            <Stack.Screen name="Nested" component={NestedScreen} options={{ title: '入れ子スクロール' }} />
            <Stack.Screen name="Chat" component={ChatScreen} options={{ title: '反転チャット' }} />
            <Stack.Screen name="Loading" component={LoadingScreen} options={{ title: '読み込みの状態' }} />
            <Stack.Screen
              name="SwipeActions"
              component={SwipeActionsScreen}
              options={{ title: 'スワイプの操作' }}
            />
            <Stack.Screen name="Select" component={SelectScreen} options={{ title: '選択モード' }} />
            <Stack.Screen name="Links" component={LinksScreen} options={{ title: '文中リンク' }} />
            <Stack.Screen name="Pin" component={PinScreen} options={{ title: 'PIN と OTP' }} />
            <Stack.Screen name="BackGuard" component={BackGuardScreen} options={{ title: '戻るの横取り' }} />
            <Stack.Screen name="Editor" component={EditorScreen} options={{ title: '編集' }} />
            <Stack.Screen name="Player" component={PlayerScreen} options={{ title: '引き伸ばせるシート' }} />
            <Stack.Screen
              name="HideBars"
              component={HideBarsScreen}
              options={{ title: 'スクロールで隠れるバー' }}
            />
            <Stack.Screen
              name="TabHeader"
              component={TabHeaderScreen}
              options={{ title: '折りたたみヘッダとタブ' }}
            />
            <Stack.Screen
              name="Staggered"
              component={StaggeredScreen}
              options={{ title: '高さの揃わないグリッド' }}
            />
          </Stack.Navigator>
        </NavigationContainer>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

export default App;
