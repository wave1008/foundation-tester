import React, { useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { ActivityIndicator, IconButton, ProgressBar } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const DURATION_MS = 2000;
const QTY_MIN = 0;
const QTY_MAX = 10;

const glyph = (char: string) =>
  ({ size, color }: { size: number; color: string }) => (
    <Text style={{ fontSize: size, color }}>{char}</Text>
  );

export function StepperScreen() {
  const [qty, setQty] = useState(1);
  const [progress, setProgress] = useState(0);
  const [state, setState] = useState<'idle' | 'running' | 'done'>('idle');
  const rafRef = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (rafRef.current !== null) cancelAnimationFrame(rafRef.current);
    },
    [],
  );

  const startProgress = () => {
    if (state === 'running') return;
    setState('running');
    setProgress(0);
    const start = Date.now();
    const tick = () => {
      const value = Math.min((Date.now() - start) / DURATION_MS, 1);
      setProgress(value);
      if (value >= 1) {
        setState('done');
        rafRef.current = null;
      } else {
        rafRef.current = requestAnimationFrame(tick);
      }
    };
    rafRef.current = requestAnimationFrame(tick);
  };

  return (
    <ScreenContainer>
      <View testID={Tags.stepperQty} style={styles.stepper}>
        <IconButton
          testID={Tags.btnQtyMinus}
          accessibilityLabel="減らす"
          icon={glyph('-')}
          onPress={() => setQty(q => Math.max(QTY_MIN, q - 1))}
        />
        <EchoText testID={Tags.txtQty}>{`qty=${qty}`}</EchoText>
        <IconButton
          testID={Tags.btnQtyPlus}
          accessibilityLabel="増やす"
          icon={glyph('+')}
          onPress={() => setQty(q => Math.min(QTY_MAX, q + 1))}
        />
      </View>

      <TaggedButton testID={Tags.btnStartProgress} label="進捗を開始" onPress={startProgress} />
      <ProgressBar testID={Tags.progressMain} progress={progress} />
      <EchoText testID={Tags.txtProgress}>{`progress=${state}`}</EchoText>
      {state === 'running' && <ActivityIndicator testID={Tags.spinnerBusy} animating />}
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  stepper: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
});
