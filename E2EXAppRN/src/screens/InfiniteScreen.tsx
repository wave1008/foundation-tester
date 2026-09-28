import React, { useEffect, useRef, useState } from 'react';
import { FlatList, StyleSheet } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const PAGE_SIZE = 20;
const MAX_ROWS = 100;
const LOAD_DELAY_MS = 800;

export function InfiniteScreen() {
  const [rows, setRows] = useState(() => Array.from({ length: PAGE_SIZE }, (_, n) => n));
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState('infinite=none');
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // onEndReached は使わない: マウント直後に1回発火し、同じ長さのままでは2回目が来ない(捨てると読み込みが
  // 二度と始まらない)。onScroll で末尾への近さを見る。onScrollBeginDrag は指のドラッグでしか来ないので
  // 使わない(a11y・プログラムからの送りでも読み込むため)
  const hasScrolledRef = useRef(false);

  useEffect(
    () => () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    },
    [],
  );

  const loadMore = () => {
    if (!hasScrolledRef.current) return;
    if (loading || rows.length >= MAX_ROWS) return;
    setLoading(true);
    timerRef.current = setTimeout(() => {
      setRows(prev => {
        const next = Math.min(prev.length + PAGE_SIZE, MAX_ROWS);
        return Array.from({ length: next }, (_, n) => n);
      });
      setLoading(false);
    }, LOAD_DELAY_MS);
  };

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtInfiniteCount}>{`loaded=${rows.length}`}</EchoText>
      <EchoText testID={Tags.txtInfiniteResult}>{result}</EchoText>
      <FlatList
        testID={Tags.listInfinite}
        style={styles.list}
        data={rows}
        keyExtractor={n => String(n)}
        scrollEventThrottle={16}
        onScroll={e => {
          const { contentOffset, contentSize, layoutMeasurement } = e.nativeEvent;
          if (contentOffset.y > 0) hasScrolledRef.current = true;
          if (contentOffset.y + layoutMeasurement.height >= contentSize.height - layoutMeasurement.height * 0.5) {
            loadMore();
          }
        }}
        renderItem={({ item }) => (
          <TaggedButton
            testID={Tags.rowI(item)}
            label={`項目 ${String(item).padStart(2, '0')}`}
            onPress={() => setResult(`infinite=${Tags.rowI(item)}`)}
            style={styles.row}
          />
        )}
        ListFooterComponent={
          loading ? (
            <EchoText testID={Tags.txtLoading} style={styles.loading}>
              読み込み中
            </EchoText>
          ) : null
        }
      />
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  list: {
    flex: 1,
  },
  row: {
    marginVertical: 2,
  },
  loading: {
    textAlign: 'center',
    padding: 12,
  },
});
