import React, { useState } from 'react';
import { FlatList, RefreshControl, StyleSheet } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

const ROWS = Array.from({ length: 20 }, (_, n) => n);

export function RefreshScreen() {
  const [refreshing, setRefreshing] = useState(false);
  const [count, setCount] = useState(0);

  const onRefresh = () => {
    setRefreshing(true);
    setTimeout(() => {
      setCount(c => c + 1);
      setRefreshing(false);
    }, 1000);
  };

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtRefreshCount}>{`refresh=${count}`}</EchoText>
      <FlatList
        testID={Tags.boxRefresh}
        style={styles.list}
        data={ROWS}
        keyExtractor={n => String(n)}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        renderItem={({ item }) => (
          <EchoText testID={Tags.rowRefresh(item)} style={styles.row}>
            {`更新行 ${String(item).padStart(2, '0')}`}
          </EchoText>
        )}
      />
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  list: {
    flex: 1,
  },
  row: {
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#cccccc',
  },
});
