import React, { useEffect, useRef, useState } from 'react';
import { Snackbar } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const LONG_MS = 10000;
const SHORT_MS = 4000;

export function SnackbarScreen() {
  const [longVisible, setLongVisible] = useState(false);
  const [shortVisible, setShortVisible] = useState(false);
  const [result, setResult] = useState('snackbar=none');
  // 自前タイマーで dismiss 種別(action か timeout か)を確定させる。paper の Snackbar 自身も
  // duration 経過で onDismiss を呼ぶが、action 押下時にも onDismiss が呼ばれるかは版依存なので、
  // タイマーを自分で持って onDismiss 側は「まだ何も確定していなければ dismissed」に倒す。
  const longTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const shortTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (longTimer.current) clearTimeout(longTimer.current);
      if (shortTimer.current) clearTimeout(shortTimer.current);
    },
    [],
  );

  const showLong = () => {
    setLongVisible(true);
    if (longTimer.current) clearTimeout(longTimer.current);
    longTimer.current = setTimeout(() => {
      setLongVisible(false);
      setResult('snackbar=dismissed');
    }, LONG_MS);
  };

  const showShort = () => {
    setShortVisible(true);
    if (shortTimer.current) clearTimeout(shortTimer.current);
    shortTimer.current = setTimeout(() => {
      setShortVisible(false);
      setResult('snackbar=short-dismissed');
    }, SHORT_MS);
  };

  const undo = () => {
    if (longTimer.current) clearTimeout(longTimer.current);
    setLongVisible(false);
    setResult('snackbar=undo');
  };

  return (
    <ScreenContainer>
      <TaggedButton testID={Tags.btnShowSnackbar} label="スナックバーを出す" onPress={showLong} />
      <TaggedButton
        testID={Tags.btnShowSnackbarShort}
        label="短いスナックバー"
        onPress={showShort}
      />
      <EchoText testID={Tags.txtSnackbarResult}>{result}</EchoText>

      <Snackbar
        visible={longVisible}
        onDismiss={() => setLongVisible(false)}
        duration={LONG_MS}
        action={{ label: '元に戻す', onPress: undo }}
      >
        削除しました
      </Snackbar>
      <Snackbar visible={shortVisible} onDismiss={() => setShortVisible(false)} duration={SHORT_MS}>
        保存しました
      </Snackbar>
    </ScreenContainer>
  );
}
