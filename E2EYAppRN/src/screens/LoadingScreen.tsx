import React, { useCallback, useEffect, useRef, useState } from 'react';
import { FlatList, NativeScrollEvent, NativeSyntheticEvent, Pressable, StyleSheet, View } from 'react-native';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

type Phase = 'loading' | 'loaded' | 'footer-loading' | 'error' | 'end';

const FIRST_LOAD_MS = 2000;
const FOOTER_LOAD_MS = 1000;
const SKELETON_ROWS = 8;
const PAGE1 = 30;
const PAGE2 = 50;
const END_MARGIN = 8;

const label = (n: number) => `記事 ${String(n).padStart(2, '0')}`;

export function LoadingScreen() {
  const [phase, setPhase] = useState<Phase>('loading');
  const [count, setCount] = useState(PAGE1);
  const [result, setResult] = useState('loading=none');
  const failedOnce = useRef(false);
  const lastY = useRef(0);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const later = (ms: number, fn: () => void) => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(fn, ms);
  };

  const start = useCallback(() => {
    failedOnce.current = false;
    setCount(PAGE1);
    setResult('loading=none');
    setPhase('loading');
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setPhase('loaded'), FIRST_LOAD_MS);
  }, []);

  useEffect(() => {
    start();
    return () => {
      if (timer.current) clearTimeout(timer.current);
    };
  }, [start]);

  const loadMore = () => {
    setPhase('footer-loading');
    later(FOOTER_LOAD_MS, () => {
      if (!failedOnce.current) {
        failedOnce.current = true;
        setPhase('error');
      } else {
        setCount(PAGE2);
        setPhase('loaded');
      }
    });
  };

  const onScroll = (e: NativeSyntheticEvent<NativeScrollEvent>) => {
    const { contentOffset, contentSize, layoutMeasurement } = e.nativeEvent;
    // 前方へ動いたときだけ判定する(内容の増減に伴う補正の onScroll で末尾と誤判定しない)
    const forward = contentOffset.y > lastY.current;
    lastY.current = contentOffset.y;
    if (phase !== 'loaded' || !forward) return;
    if (contentOffset.y + layoutMeasurement.height < contentSize.height - END_MARGIN) return;
    if (count >= PAGE2) setPhase('end');
    else loadMore();
  };

  const state = phase === 'footer-loading' ? 'loading' : phase;
  const rows = Array.from({ length: count }, (_, n) => n);

  const footer =
    phase === 'footer-loading' ? (
      <EchoText testID={Tags.txtFooterLoading} style={styles.footer}>
        読み込み中
      </EchoText>
    ) : phase === 'error' ? (
      <View style={styles.footerBox}>
        <EchoText testID={Tags.txtFooterError} style={styles.footer}>
          読み込みに失敗しました
        </EchoText>
        <TaggedButton
          testID={Tags.btnRetry}
          label="再試行"
          onPress={() => {
            setPhase('footer-loading');
            later(FOOTER_LOAD_MS, () => {
              setCount(PAGE2);
              setPhase('loaded');
            });
          }}
        />
      </View>
    ) : phase === 'end' ? (
      <EchoText testID={Tags.txtFooterEnd} style={styles.footer}>
        これ以上ありません
      </EchoText>
    ) : null;

  return (
    <View style={styles.root}>
      <View style={styles.echo}>
        <EchoText testID={Tags.txtLoadingState}>{`state=${state}`}</EchoText>
        <EchoText testID={Tags.txtLoadingCount}>{`loaded=${phase === 'loading' ? 0 : count}`}</EchoText>
        <EchoText testID={Tags.txtLoadingResult}>{result}</EchoText>
        <TaggedButton testID={Tags.btnReload} label="読み込み直す" onPress={start} />
      </View>
      {phase === 'loading' ? (
        <View style={styles.list}>
          {Array.from({ length: SKELETON_ROWS }, (_, n) => (
            // 本物と同じ #id・ラベルで押せない(enabled=false)
            <Pressable
              key={n}
              testID={Tags.rowL(n)}
              accessible
              accessibilityRole="button"
              accessibilityLabel={label(n)}
              accessibilityState={{ disabled: true }}
              disabled
              style={styles.skeleton}
            />
          ))}
        </View>
      ) : (
        <FlatList
          style={styles.list}
          data={rows}
          keyExtractor={n => String(n)}
          scrollEventThrottle={16}
          onScroll={onScroll}
          ListFooterComponent={footer}
          renderItem={({ item }) => (
            <TaggedButton
              testID={Tags.rowL(item)}
              label={label(item)}
              onPress={() => setResult(`loading=${Tags.rowL(item)}`)}
              style={styles.row}
            />
          )}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#ffffff' },
  echo: { padding: 8, gap: 2 },
  list: { flex: 1 },
  row: { height: 56, marginVertical: 2, marginHorizontal: 8 },
  skeleton: { height: 56, marginVertical: 2, marginHorizontal: 8, borderRadius: 6, backgroundColor: '#d9d9d9' },
  footerBox: { alignItems: 'center', padding: 12, gap: 8 },
  footer: { textAlign: 'center', padding: 12 },
});
