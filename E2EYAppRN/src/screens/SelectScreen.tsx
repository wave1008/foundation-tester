import React, { useState } from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

const pad2 = (n: number) => String(n).padStart(2, '0');

export function SelectScreen() {
  const [rows, setRows] = useState(Array.from({ length: 20 }, (_, k) => k + 1));
  const [selectMode, setSelectMode] = useState(false);
  const [selected, setSelected] = useState<number[]>([]);
  const [result, setResult] = useState('select=none');

  const exit = () => {
    setSelectMode(false);
    setSelected([]);
  };

  const toggle = (n: number) =>
    setSelected(prev => (prev.includes(n) ? prev.filter(x => x !== n) : [...prev, n]));

  const pressRow = (n: number) => {
    if (selectMode) toggle(n);
    else setResult(`select=open:${Tags.selRow(n)}`);
  };

  const longPressRow = (n: number) => {
    if (!selectMode) {
      setSelectMode(true);
      setSelected([n]);
    }
  };

  return (
    <View style={styles.root}>
      <View style={styles.echo}>
        <EchoText testID={Tags.txtSelectMode}>{`mode=${selectMode ? 'select' : 'normal'}`}</EchoText>
        <EchoText testID={Tags.txtSelectCount}>{`selected=${selected.length}`}</EchoText>
        <EchoText testID={Tags.txtSelectResult}>{result}</EchoText>
      </View>
      <View style={styles.bar}>
        <TaggedButton
          testID={Tags.btnEdit}
          label={selectMode ? '完了' : '編集'}
          onPress={() => (selectMode ? exit() : setSelectMode(true))}
        />
      </View>
      {selectMode && (
        <View style={styles.bar}>
          <TaggedButton testID={Tags.btnSelAll} label="すべて選択" onPress={() => setSelected(rows)} />
          <TaggedButton
            testID={Tags.btnSelDelete}
            label="削除"
            onPress={() => {
              const gone = [...selected].sort((a, b) => a - b);
              setRows(prev => prev.filter(n => !gone.includes(n)));
              setResult(`select=deleted:${gone.map(pad2).join(',')}`);
              exit();
            }}
          />
          <Pressable
            testID={Tags.btnSelCancel}
            accessible
            accessibilityRole="button"
            accessibilityLabel="キャンセル"
            onPress={exit}
            style={styles.iconButton}
          >
            <Text importantForAccessibility="no-hide-descendants" accessibilityElementsHidden>
              ✕
            </Text>
          </Pressable>
        </View>
      )}
      <FlatList
        data={rows}
        keyExtractor={n => String(n)}
        extraData={[selectMode, selected]}
        renderItem={({ item }) => {
          const isSel = selected.includes(item);
          return (
            <Pressable
              testID={Tags.selRow(item)}
              accessible
              accessibilityRole="button"
              accessibilityLabel={`項目 ${pad2(item)}`}
              accessibilityState={{ selected: isSel }}
              onPress={() => pressRow(item)}
              onLongPress={() => longPressRow(item)}
              style={[styles.row, isSel && styles.rowSelected]}
            >
              <Text
                style={styles.rowText}
                importantForAccessibility="no-hide-descendants"
                accessibilityElementsHidden
              >
                {`${selectMode ? (isSel ? '☑ ' : '☐ ') : ''}項目 ${pad2(item)}`}
              </Text>
            </Pressable>
          );
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#ffffff' },
  echo: { padding: 8, gap: 2 },
  bar: { flexDirection: 'row', gap: 8, paddingHorizontal: 8, paddingBottom: 6 },
  iconButton: {
    minHeight: 44,
    minWidth: 44,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#e6e6e6',
    borderRadius: 6,
  },
  row: {
    minHeight: 52,
    justifyContent: 'center',
    paddingHorizontal: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#cccccc',
  },
  rowSelected: { backgroundColor: '#dbeafe' },
  rowText: { fontSize: 16 },
});
