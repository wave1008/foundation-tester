import React, { useState } from 'react';
import { ScrollView, StyleSheet, Text } from 'react-native';
import { Appbar, AnimatedFAB, FAB } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

const ROWS = Array.from({ length: 30 }, (_, n) => n);

const glyph = (char: string) =>
  ({ size, color }: { size: number; color: string }) => (
    <Text style={{ fontSize: size, color }}>{char}</Text>
  );

export function FabScreen() {
  const [result, setResult] = useState('fab=none');

  return (
    <ScreenContainer style={styles.screen}>
      <EchoText testID={Tags.txtFabResult}>{result}</EchoText>
      <ScrollView contentContainerStyle={styles.list}>
        {ROWS.map(n => (
          <EchoText key={n} testID={Tags.rowF(n)} style={styles.row}>
            {`行 F${String(n).padStart(2, '0')}`}
          </EchoText>
        ))}
      </ScrollView>

      <FAB
        testID={Tags.fabAdd}
        icon={glyph('+')}
        accessibilityLabel="追加"
        style={styles.fabAdd}
        onPress={() => setResult('fab=add')}
      />
      <AnimatedFAB
        testID={Tags.fabExtended}
        icon={glyph('+')}
        label="新規作成"
        extended
        animateFrom="right"
        iconMode="static"
        style={styles.fabExtended}
        onPress={() => setResult('fab=extended')}
      />

      <Appbar style={styles.bottomBar}>
        <Appbar.Action
          testID={Tags.barActionSearch}
          icon={glyph('⌕')}
          accessibilityLabel="検索"
          onPress={() => setResult('fab=search')}
        />
        <Appbar.Action
          testID={Tags.barActionShare}
          icon={glyph('↗')}
          accessibilityLabel="共有"
          onPress={() => setResult('fab=share')}
        />
      </Appbar>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  screen: {
    padding: 0,
  },
  list: {
    padding: 16,
    paddingBottom: 96,
  },
  row: {
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#cccccc',
  },
  fabAdd: {
    position: 'absolute',
    right: 16,
    bottom: 80,
  },
  fabExtended: {
    position: 'absolute',
    left: 16,
    bottom: 80,
  },
  bottomBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
  },
});
