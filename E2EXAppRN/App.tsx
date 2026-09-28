/**
 * FT E2EX RN — fleetest 用の SUT アプリ(React Native の定番部品の実験場)。
 * 画面構成・#id・ラベルの唯一の正は E2EXAppCMP/docs/ui-contract.md。
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
import { PaperProvider } from 'react-native-paper';
import { BottomSheetModalProvider } from '@gorhom/bottom-sheet';

import type { RootStackParamList } from './src/navigation';
import { AnimScreen } from './src/screens/AnimScreen';
import { ArgNavScreen } from './src/screens/ArgNavScreen';
import { BottomSheetScreen } from './src/screens/BottomSheetScreen';
import { ChipsScreen } from './src/screens/ChipsScreen';
import { DatePickerScreen } from './src/screens/DatePickerScreen';
import { DetailScreen } from './src/screens/DetailScreen';
import { DrawerScreen } from './src/screens/DrawerScreen';
import { GridScreen } from './src/screens/GridScreen';
import { HomeScreen } from './src/screens/HomeScreen';
import { MenuScreen } from './src/screens/MenuScreen';
import { PagerScreen } from './src/screens/PagerScreen';
import { RefreshScreen } from './src/screens/RefreshScreen';
import { SearchScreen } from './src/screens/SearchScreen';
import { SnackbarScreen } from './src/screens/SnackbarScreen';
import { SwipeScreen } from './src/screens/SwipeScreen';
import { TabsScreen } from './src/screens/TabsScreen';
import { TooltipScreen } from './src/screens/TooltipScreen';
import { CollapseScreen } from './src/screens/CollapseScreen';
import { StickyScreen } from './src/screens/StickyScreen';
import { TimeScreen } from './src/screens/TimeScreen';
import { DialogsScreen } from './src/screens/DialogsScreen';
import { ContextScreen } from './src/screens/ContextScreen';
import { ReorderScreen } from './src/screens/ReorderScreen';
import { InputsScreen } from './src/screens/InputsScreen';
import { FabScreen } from './src/screens/FabScreen';
import { ExpandScreen } from './src/screens/ExpandScreen';
import { StepperScreen } from './src/screens/StepperScreen';
import { InfiniteScreen } from './src/screens/InfiniteScreen';
import { ZoomScreen } from './src/screens/ZoomScreen';
import { NativeScreen } from './src/screens/NativeScreen';

enableScreens();

const Stack = createNativeStackNavigator<RootStackParamList>();

function App() {
  const isDarkMode = useColorScheme() === 'dark';
  return (
    // GestureHandlerRootView はツリー全体を包む(gesture-handler の必須要件)。
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
        {/* vector-icons を使わない: PaperProvider の settings.icon で既定アイコンを差し替え、
            ビルド安定性を優先する(ドキュメント記載の公式回避策)。 */}
        <PaperProvider
          settings={{
            icon: ({ size, color }) => <Text style={{ fontSize: size, color }}>●</Text>,
          }}
        >
          <BottomSheetModalProvider>
            <NavigationContainer>
              <Stack.Navigator
                screenOptions={{
                  headerTitle: props => <Text testID="txt_screen_title">{props.children}</Text>,
                  // 契約の #btn_back は付けない: native-stack 既定の戻るボタンは
                  // ネイティブ描画(iOS = UINavigationBar 標準ボタン、Android = Toolbar の
                  // ナビゲーションアイコン)で testID を通せない。docs/ui-contract.md に
                  // 実際のラベル(iOS: 前画面タイトル or "Back" / Android: 内容記述
                  // "Navigate up")を記録している。displayMode=minimal でラベルを出さず
                  // シェブロンだけにして、5 SUT の見た目差を縮める。
                  headerBackButtonDisplayMode: 'minimal',
                }}
              >
                <Stack.Screen name="Home" component={HomeScreen} options={{ title: 'E2EX ホーム' }} />
                <Stack.Screen name="Pager" component={PagerScreen} options={{ title: 'ページャ' }} />
                <Stack.Screen name="Sheet" component={BottomSheetScreen} options={{ title: 'ボトムシート' }} />
                <Stack.Screen name="Menu" component={MenuScreen} options={{ title: 'メニュー' }} />
                <Stack.Screen
                  name="DatePicker"
                  component={DatePickerScreen}
                  options={{ title: '日付ピッカー' }}
                />
                <Stack.Screen name="Drawer" component={DrawerScreen} options={{ title: 'ドロワー' }} />
                <Stack.Screen
                  name="Refresh"
                  component={RefreshScreen}
                  options={{ title: '引っ張って更新' }}
                />
                <Stack.Screen
                  name="Snackbar"
                  component={SnackbarScreen}
                  options={{ title: 'スナックバー' }}
                />
                <Stack.Screen name="Grid" component={GridScreen} options={{ title: 'グリッド' }} />
                <Stack.Screen
                  name="Swipe"
                  component={SwipeScreen}
                  options={{ title: 'スワイプで削除' }}
                />
                <Stack.Screen name="Tabs" component={TabsScreen} options={{ title: 'タブ' }} />
                <Stack.Screen name="Anim" component={AnimScreen} options={{ title: 'アニメーション' }} />
                <Stack.Screen
                  name="Tooltip"
                  component={TooltipScreen}
                  options={{ title: 'ツールチップ' }}
                />
                <Stack.Screen
                  name="Chips"
                  component={ChipsScreen}
                  options={{ title: 'チップと分割ボタン' }}
                />
                <Stack.Screen name="Search" component={SearchScreen} options={{ title: '検索バー' }} />
                <Stack.Screen
                  name="ArgNav"
                  component={ArgNavScreen}
                  options={{ title: '引数付き遷移' }}
                />
                <Stack.Screen name="Detail" component={DetailScreen} options={{ title: '詳細' }} />
                <Stack.Screen
                  name="Collapse"
                  component={CollapseScreen}
                  options={{ title: '伸縮するヘッダ' }}
                />
                <Stack.Screen
                  name="Sticky"
                  component={StickyScreen}
                  options={{ title: '貼り付く見出し' }}
                />
                <Stack.Screen name="Time" component={TimeScreen} options={{ title: '時刻ピッカー' }} />
                <Stack.Screen
                  name="Dialogs"
                  component={DialogsScreen}
                  options={{ title: 'ダイアログ' }}
                />
                <Stack.Screen
                  name="Context"
                  component={ContextScreen}
                  options={{ title: '長押しメニュー' }}
                />
                <Stack.Screen
                  name="Reorder"
                  component={ReorderScreen}
                  options={{ title: '並べ替え' }}
                />
                <Stack.Screen
                  name="Inputs"
                  component={InputsScreen}
                  options={{ title: '入力の種類' }}
                />
                <Stack.Screen name="Fab" component={FabScreen} options={{ title: 'FAB' }} />
                <Stack.Screen
                  name="Expand"
                  component={ExpandScreen}
                  options={{ title: '展開するリスト' }}
                />
                <Stack.Screen
                  name="Stepper"
                  component={StepperScreen}
                  options={{ title: 'ステッパーと進捗' }}
                />
                <Stack.Screen
                  name="Infinite"
                  component={InfiniteScreen}
                  options={{ title: '無限スクロール' }}
                />
                <Stack.Screen name="Zoom" component={ZoomScreen} options={{ title: 'ピンチで拡大' }} />
                <Stack.Screen
                  name="Native"
                  component={NativeScreen}
                  options={{ title: '固有部品' }}
                />
              </Stack.Navigator>
            </NavigationContainer>
          </BottomSheetModalProvider>
        </PaperProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

export default App;
