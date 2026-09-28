import React, { useState } from 'react';
import { Pressable, StyleSheet, Text } from 'react-native';
import { Menu } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

const ROWS = [1, 2, 3];

export function ContextScreen() {
  const [openRow, setOpenRow] = useState<number | null>(null);
  const [result, setResult] = useState('context=none');

  const select = (n: number, action: string) => {
    setResult(`context=row${n}:${action}`);
    setOpenRow(null);
  };

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtContextResult}>{result}</EchoText>
      {ROWS.map(n => (
        <Menu
          key={n}
          visible={openRow === n}
          onDismiss={() => setOpenRow(null)}
          anchor={
            <Pressable
              testID={Tags.ctxRow(n)}
              accessible
              accessibilityRole="button"
              accessibilityLabel={`長押し行 ${n}`}
              onLongPress={() => setOpenRow(n)}
              style={styles.row}
            >
              <Text
                style={styles.rowLabel}
                importantForAccessibility="no-hide-descendants"
                accessibilityElementsHidden
              >
                {`長押し行 ${n}`}
              </Text>
            </Pressable>
          }
        >
          <Menu.Item title="編集" onPress={() => select(n, 'edit')} />
          <Menu.Item title="複製" onPress={() => select(n, 'copy')} />
          <Menu.Item title="削除" onPress={() => select(n, 'delete')} />
        </Menu>
      ))}
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  row: {
    minHeight: 56,
    justifyContent: 'center',
    paddingHorizontal: 16,
    backgroundColor: '#f2f2f2',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#cccccc',
  },
  rowLabel: {
    fontSize: 16,
  },
});
