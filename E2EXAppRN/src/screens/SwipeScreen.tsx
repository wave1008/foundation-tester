import React, { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { Swipeable } from 'react-native-gesture-handler';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

export function SwipeScreen() {
  const [rows, setRows] = useState([1, 2, 3, 4, 5]);
  const [result, setResult] = useState('removed=none');

  const remove = (id: number) => {
    setRows(prev => prev.filter(r => r !== id));
    setResult(`removed=${id}`);
  };

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtSwipeResult}>{result}</EchoText>
      <EchoText testID={Tags.txtSwipeCount}>{`rows=${rows.length}`}</EchoText>
      {rows.map(id => (
        <Swipeable
          key={id}
          // 右から左(EndToStart)だけ有効。左から右のドラッグに renderLeftActions を渡さないと
          // 何も出ず、リリース時に自動で元位置へ戻る(enableDismissFromStartToEnd=false 相当)。
          renderRightActions={() => <View style={styles.action} />}
          onSwipeableOpen={direction => {
            if (direction === 'right') {
              remove(id);
            }
          }}
        >
          <View style={styles.row}>
            <EchoText testID={Tags.swipeRow(id)}>{`スワイプ行 ${id}`}</EchoText>
          </View>
        </Swipeable>
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
  action: {
    width: 1,
  },
});
