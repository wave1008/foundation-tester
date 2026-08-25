/**
 * FT E2E RN — fleetest 用の SUT アプリ。
 * 契約(#id・ラベル・画面構成)の唯一の正は E2EAppCMP/docs/ui-contract.md。
 *
 * @format
 */

import React, { useEffect, useState } from 'react';
import { Linking, StatusBar, useColorScheme } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { resolveDeepLinkScreen } from './src/deeplink';
import { HomeChildScreen } from './src/navigation';
import {
  bootstrapPersistedState,
  persistAutoDialog,
  persistHealSchemaV1,
  PersistedState,
  resetLaunchCount,
} from './src/persistence';
import { AboutScreen } from './src/screens/AboutScreen';
import { AsyncScreen } from './src/screens/AsyncScreen';
import { ControlsScreen } from './src/screens/ControlsScreen';
import { DiagnosticsScreen } from './src/screens/DiagnosticsScreen';
import { DialogScreen } from './src/screens/DialogScreen';
import { GestureScreen } from './src/screens/GestureScreen';
import { HealScreen } from './src/screens/HealScreen';
import { HomeScreen } from './src/screens/HomeScreen';
import { InputScreen } from './src/screens/InputScreen';
import { LifecycleScreen } from './src/screens/LifecycleScreen';
import { MapScreen } from './src/screens/MapScreen';
import { NoIdScreen } from './src/screens/NoIdScreen';
import { ScrollScreen } from './src/screens/ScrollScreen';
import { SelectorScreen } from './src/screens/SelectorScreen';
import { WebViewScreen } from './src/screens/WebViewScreen';
import { AppTab, ScreenShell } from './src/ui';

function App() {
  const isDarkMode = useColorScheme() === 'dark';
  return (
    <SafeAreaProvider>
      <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
      <AppRoot />
    </SafeAreaProvider>
  );
}

// 起動時の永続値読み込み(launch を+1)が終わるまでは何も描かない。AsyncStorage の読み出しは
// 端末上ではほぼ瞬時に終わるため、白画面が視認されることは無い想定(要実機確認)。
function AppRoot() {
  const [persisted, setPersisted] = useState<PersistedState | null>(null);

  useEffect(() => {
    bootstrapPersistedState().then(setPersisted);
  }, []);

  if (!persisted) {
    return null;
  }
  return <AppShell initialPersisted={persisted} />;
}

const HOME_TITLES: Record<HomeChildScreen, string> = {
  selector: 'セレクタ',
  input: 'テキスト入力',
  gesture: 'ジェスチャ',
  map: 'マップ',
  scroll: 'スクロール',
  async: '非同期表示',
  dialog: 'ダイアログ',
  lifecycle: 'ライフサイクル',
  heal: '自己修復',
  diagnostics: '診断',
  noid: 'ID なし',
  webview: 'WebView',
};

// プロセス起動ごとに state が初期値へ戻る = 「起動時は必ずホームタブのルートに戻る」契約が成立する。
function AppShell({ initialPersisted }: { initialPersisted: PersistedState }) {
  const [tab, setTab] = useState<AppTab>('home');
  const [homeChild, setHomeChild] = useState<HomeChildScreen | null>(null);
  const [sessionCount, setSessionCount] = useState(0);
  const [launchCount, setLaunchCount] = useState(initialPersisted.launchCount);
  const [autoDialog, setAutoDialog] = useState(initialPersisted.autoDialog);
  const [healSchemaV1, setHealSchemaV1] = useState(initialPersisted.healSchemaV1);
  const [lastDeeplink, setLastDeeplink] = useState('-');

  // タブ切替は下位画面スタックを捨てて各タブのルートへ着地する(契約 §シェル)。
  const switchTab = (next: AppTab) => {
    setTab(next);
    setHomeChild(null);
  };

  // 起動時リセット(上の useState 初期値 = ホームのルート)が確定した後にディープリンクを適用する
  // (契約 E2EAppCMP/docs/ui-contract.md §ディープリンク)。getInitialURL は cold launch
  // (launchApp(url:))、'url' イベントは warm(openURL)を担う。iOS/Android とも native 側の配線は
  // ios/FTE2ERN/AppDelegate.swift・android/…/MainActivity.kt + AndroidManifest.xml。
  useEffect(() => {
    const applyDeepLink = (url: string) => {
      setLastDeeplink(url);
      const screen = resolveDeepLinkScreen(url);
      if (screen !== null) {
        setTab('home');
        setHomeChild(screen);
      }
    };
    Linking.getInitialURL().then(url => {
      if (url) {
        applyDeepLink(url);
      }
    });
    const subscription = Linking.addEventListener('url', ({ url }) => applyDeepLink(url));
    return () => subscription.remove();
  }, []);

  const handleAutoDialogChange = (v: boolean) => {
    setAutoDialog(v);
    persistAutoDialog(v);
  };

  const handleHealSchemaChange = (v: boolean) => {
    setHealSchemaV1(v);
    persistHealSchemaV1(v);
  };

  const handleResetLaunch = () => {
    resetLaunchCount().then(setLaunchCount);
  };

  const title =
    tab === 'controls' ? 'コントロール' : tab === 'about' ? '情報' : homeChild === null ? 'ホーム' : HOME_TITLES[homeChild];

  let content: React.ReactNode;
  if (tab === 'controls') {
    content = <ControlsScreen />;
  } else if (tab === 'about') {
    content = <AboutScreen />;
  } else {
    switch (homeChild) {
      case null:
        content = <HomeScreen onNavigate={setHomeChild} />;
        break;
      case 'selector':
        content = <SelectorScreen />;
        break;
      case 'input':
        content = <InputScreen />;
        break;
      case 'gesture':
        content = <GestureScreen onOpenMap={() => setHomeChild('map')} />;
        break;
      case 'map':
        content = <MapScreen />;
        break;
      case 'scroll':
        content = <ScrollScreen />;
        break;
      case 'async':
        content = <AsyncScreen />;
        break;
      case 'dialog':
        content = <DialogScreen auto={autoDialog} onAutoChange={handleAutoDialogChange} />;
        break;
      case 'lifecycle':
        content = (
          <LifecycleScreen
            launchCount={launchCount}
            sessionCount={sessionCount}
            lastDeeplink={lastDeeplink}
            onSessionIncrement={() => setSessionCount(c => c + 1)}
            onResetLaunch={handleResetLaunch}
          />
        );
        break;
      case 'heal':
        content = <HealScreen schemaV1={healSchemaV1} onSchemaChange={handleHealSchemaChange} />;
        break;
      case 'diagnostics':
        content = <DiagnosticsScreen />;
        break;
      case 'noid':
        content = <NoIdScreen />;
        break;
      case 'webview':
        content = <WebViewScreen />;
        break;
    }
  }

  return (
    <ScreenShell
      title={title}
      showBack={tab === 'home' && homeChild !== null}
      onBack={() => setHomeChild(null)}
      activeTab={tab}
      onTabChange={switchTab}
    >
      {content}
    </ScreenShell>
  );
}

export default App;
