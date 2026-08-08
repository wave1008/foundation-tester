import React from 'react';

import { HomeChildScreen } from '../navigation';
import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

// 11 行 + マーカーが1画面に収まらない場合はスクロール可にする(契約どおり)。
// noid/webview は末尾に置かない(下部タブに重なりタップが吸われる実害があるため)。
export function HomeScreen({
  onNavigate,
}: {
  onNavigate: (screen: HomeChildScreen) => void;
}) {
  return (
    <ScreenContainer>
      <EchoText testID={Tags.homeMarker}>E2E ホーム</EchoText>
      <TaggedButton testID={Tags.navSelector} label="セレクタ" fillWidth onPress={() => onNavigate('selector')} />
      <TaggedButton testID={Tags.navNoid} label="ID なし" fillWidth onPress={() => onNavigate('noid')} />
      <TaggedButton testID={Tags.navInput} label="テキスト入力" fillWidth onPress={() => onNavigate('input')} />
      <TaggedButton testID={Tags.navWebview} label="WebView" fillWidth onPress={() => onNavigate('webview')} />
      <TaggedButton testID={Tags.navGesture} label="ジェスチャ" fillWidth onPress={() => onNavigate('gesture')} />
      <TaggedButton testID={Tags.navScroll} label="スクロール" fillWidth onPress={() => onNavigate('scroll')} />
      <TaggedButton testID={Tags.navAsync} label="非同期表示" fillWidth onPress={() => onNavigate('async')} />
      <TaggedButton testID={Tags.navDialog} label="ダイアログ" fillWidth onPress={() => onNavigate('dialog')} />
      <TaggedButton testID={Tags.navLifecycle} label="ライフサイクル" fillWidth onPress={() => onNavigate('lifecycle')} />
      <TaggedButton testID={Tags.navHeal} label="自己修復" fillWidth onPress={() => onNavigate('heal')} />
      <TaggedButton testID={Tags.navDiagnostics} label="診断" fillWidth onPress={() => onNavigate('diagnostics')} />
    </ScreenContainer>
  );
}
