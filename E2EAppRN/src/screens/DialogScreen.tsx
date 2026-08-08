import React, { useEffect, useRef, useState } from 'react';
import { View } from 'react-native';

import { Tags } from '../tags';
import { DialogOverlay, EchoText, LabeledRow, ScreenContainer, TaggedButton, TaggedSwitch } from '../ui';

type DialogResult = 'none' | 'ok' | 'cancel';

// auto は App 側(AppShell)が保持する制御値(タブ切替やナビゲーションを跨いで最新値を
// 再表示するため、この画面のローカル state には持たせない)。永続化そのものも App 側で行う。
export function DialogScreen({
  auto,
  onAutoChange,
}: {
  auto: boolean;
  onAutoChange: (v: boolean) => void;
}) {
  const [result, setResult] = useState<DialogResult>('none');
  const [visible, setVisible] = useState(false);
  // 奇数回目だけ開く決定的な交互動作。カウンタは画面離脱(アンマウント)でリセットされる。
  const maybeCountRef = useRef(0);

  // auto=on のとき、この画面に入るたび自動でダイアログを開く(マウント後の1回だけ)。
  useEffect(() => {
    if (auto) {
      setVisible(true);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const openDialog = () => setVisible(true);

  const handleOk = () => {
    setResult('ok');
    setVisible(false);
  };
  const handleCancel = () => {
    setResult('cancel');
    setVisible(false);
  };

  const handleMaybe = () => {
    maybeCountRef.current += 1;
    if (maybeCountRef.current % 2 === 1) {
      openDialog();
    }
  };

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtDialogResult}>{`dialog=${result}`}</EchoText>
      <TaggedButton testID={Tags.btnShowDialog} label="ダイアログを開く" onPress={openDialog} />
      <TaggedButton testID={Tags.btnMaybeDialog} label="交互にダイアログ" onPress={handleMaybe} />
      <LabeledRow label="起動時ダイアログ">
        <TaggedSwitch
          testID={Tags.swAutoDialog}
          value={auto}
          onValueChange={onAutoChange}
          accessibilityLabel="起動時ダイアログ"
        />
      </LabeledRow>
      <EchoText testID={Tags.txtAutoDialog}>{`auto=${auto ? 'on' : 'off'}`}</EchoText>
      {/* back(Android)は結果を変えずに閉じるだけ(OK/キャンセルとは区別する) */}
      <DialogOverlay visible={visible} onRequestClose={() => setVisible(false)}>
        <EchoText testID={Tags.txtDialogTitle}>確認</EchoText>
        <View style={{ flexDirection: 'row', gap: 8, justifyContent: 'flex-end' }}>
          <TaggedButton testID={Tags.btnDialogCancel} label="キャンセル" onPress={handleCancel} />
          <TaggedButton testID={Tags.btnDialogOk} label="OK" onPress={handleOk} />
        </View>
      </DialogOverlay>
    </ScreenContainer>
  );
}
