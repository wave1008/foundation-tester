import React, { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { APP_VERSION, Tags } from '../tags';
import { DialogOverlay, EchoText, ScreenContainer, TaggedButton } from '../ui';

export function DiagnosticsScreen() {
  const [confirming, setConfirming] = useState(false);

  const freeze = () => {
    // ブリッジのタイムアウト挙動検証用に JS スレッドを3秒ビジーループでブロックする。
    const end = Date.now() + 3000;
    while (Date.now() < end) {
      // busy-wait
    }
  };

  const crash = () => {
    // release では未捕捉例外でプロセスが落ちる。try/catch で握りつぶされないよう
    // setTimeout でイベントループの外に出してから throw する。
    setTimeout(() => {
      throw new Error('E2E crash test');
    }, 0);
  };

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtBuildInfo}>{`build=${APP_VERSION}`}</EchoText>
      <EchoText testID={Tags.txtDiagNote}>診断メニュー</EchoText>
      {/* 背景を白固定(system の dark mode で反転すると gray220 とのコントラストが
          崩れ witness が死ぬ)。色・枠・フォントサイズは Tags.txtOcrFaint のコメント参照。 */}
      <EchoText testID={Tags.txtOcrFaint} style={styles.ocrFaintText}>
        {'ocr=readable'}
      </EchoText>
      <TaggedButton testID={Tags.btnFreeze3s} label="3秒フリーズ" onPress={freeze} />
      <TaggedButton testID={Tags.btnCrash} label="クラッシュさせる" onPress={() => setConfirming(true)} />
      <DialogOverlay visible={confirming} onRequestClose={() => setConfirming(false)}>
        <Text>クラッシュ確認</Text>
        <View style={{ flexDirection: 'row', gap: 8, justifyContent: 'flex-end' }}>
          <TaggedButton testID={Tags.btnCrashCancel} label="やめる" onPress={() => setConfirming(false)} />
          <TaggedButton
            testID={Tags.btnCrashConfirm}
            label="本当にクラッシュ"
            onPress={() => {
              setConfirming(false);
              crash();
            }}
          />
        </View>
      </DialogOverlay>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  ocrFaintText: {
    width: 160,
    height: 44,
    fontSize: 17,
    color: '#DCDCDC',
    backgroundColor: '#ffffff',
  },
});
