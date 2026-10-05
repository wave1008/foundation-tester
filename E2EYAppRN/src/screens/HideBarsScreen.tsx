import React, { useEffect, useRef, useState } from 'react';
import { FlatList, NativeScrollEvent, NativeSyntheticEvent, Pressable, StyleSheet, Text, View } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withTiming } from 'react-native-reanimated';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

const BAR_HEIGHT = 56;
const ROWS = Array.from({ length: 60 }, (_, n) => n);
// 下へ送った(offset が増えた)量がこれを超えたら隠す。戻す方向は少しでも現れる(契約)
const HIDE_DELTA = 4;
const SHOW_DELTA = 1;
const SETTLE_MS = 300;
const ANIM_MS = 200;

export function HideBarsScreen() {
  const [result, setResult] = useState('hide=none');
  const [barsEcho, setBarsEcho] = useState('shown');
  const hidden = useRef(false);
  const lastY = useRef(0);
  const settle = useRef<ReturnType<typeof setTimeout> | null>(null);
  const progress = useSharedValue(0);

  useEffect(
    () => () => {
      if (settle.current) clearTimeout(settle.current);
    },
    [],
  );

  const setHidden = (h: boolean) => {
    if (hidden.current === h) return;
    hidden.current = h;
    progress.value = withTiming(h ? 1 : 0, { duration: ANIM_MS });
  };

  const onScroll = (e: NativeSyntheticEvent<NativeScrollEvent>) => {
    const { contentOffset, contentSize, layoutMeasurement } = e.nativeEvent;
    const y = contentOffset.y;
    const maxY = contentSize.height - layoutMeasurement.height;
    const dy = y - lastY.current;
    lastY.current = y;
    // 端のバウンス(範囲外)の戻りは向きに数えない
    if (y > 0 && y < maxY) {
      if (dy > HIDE_DELTA) setHidden(true);
      else if (dy < -SHOW_DELTA) setHidden(false);
    } else if (y <= 0) {
      setHidden(false);
    }
    if (settle.current) clearTimeout(settle.current);
    settle.current = setTimeout(() => setBarsEcho(hidden.current ? 'hidden' : 'shown'), SETTLE_MS);
  };

  const topStyle = useAnimatedStyle(() => ({ transform: [{ translateY: -progress.value * BAR_HEIGHT * 1.5 }] }));
  const bottomStyle = useAnimatedStyle(() => ({ transform: [{ translateY: progress.value * BAR_HEIGHT * 1.5 }] }));
  const fabStyle = useAnimatedStyle(() => ({
    transform: [{ translateY: progress.value * (BAR_HEIGHT + 80) }],
  }));

  return (
    <View style={styles.root}>
      <View style={styles.echo}>
        <EchoText testID={Tags.txtHideResult}>{result}</EchoText>
        <EchoText testID={Tags.txtBarsState}>{`bars=${barsEcho}`}</EchoText>
      </View>
      <View style={styles.body}>
        <FlatList
          data={ROWS}
          keyExtractor={n => String(n)}
          scrollEventThrottle={16}
          onScroll={onScroll}
          contentContainerStyle={{ paddingTop: BAR_HEIGHT, paddingBottom: BAR_HEIGHT }}
          renderItem={({ item }) => (
            <TaggedButton
              testID={Tags.rowH(item)}
              label={`行 H${String(item).padStart(2, '0')}`}
              onPress={() => setResult(`hide=${Tags.rowH(item)}`)}
              style={styles.row}
            />
          )}
        />
        <Animated.View testID={Tags.barTopHiding} style={[styles.topBar, topStyle]}>
          <Text style={styles.barTitle}>受信トレイ</Text>
          <TaggedButton
            testID={Tags.btnTopAction}
            label="並べ替え"
            onPress={() => setResult('hide=top_action')}
          />
        </Animated.View>
        <Animated.View style={[styles.fabWrap, fabStyle]}>
          <Pressable
            testID={Tags.fabHiding}
            accessible
            accessibilityRole="button"
            accessibilityLabel="作成"
            onPress={() => setResult('hide=fab')}
            style={styles.fab}
          >
            <Text style={styles.fabGlyph} importantForAccessibility="no-hide-descendants" accessibilityElementsHidden>
              +
            </Text>
          </Pressable>
        </Animated.View>
        <Animated.View testID={Tags.barBottomHiding} style={[styles.bottomBar, bottomStyle]}>
          <TaggedButton testID={Tags.btnBottomA} label="受信" onPress={() => setResult('hide=bottom_a')} />
          <TaggedButton testID={Tags.btnBottomB} label="フォルダ" onPress={() => setResult('hide=bottom_b')} />
        </Animated.View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#ffffff' },
  echo: { padding: 8, gap: 2 },
  body: { flex: 1, overflow: 'hidden' },
  row: { height: 48, marginVertical: 2, marginHorizontal: 8 },
  topBar: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    height: BAR_HEIGHT,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 12,
    backgroundColor: '#f5f5f5',
  },
  barTitle: { fontSize: 18, fontWeight: '600' },
  bottomBar: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    height: BAR_HEIGHT,
    flexDirection: 'row',
    justifyContent: 'space-around',
    alignItems: 'center',
    backgroundColor: '#f5f5f5',
  },
  fabWrap: { position: 'absolute', right: 16, bottom: BAR_HEIGHT + 16 },
  fab: {
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: '#2563eb',
    alignItems: 'center',
    justifyContent: 'center',
  },
  fabGlyph: { color: '#ffffff', fontSize: 28 },
});
