import React, { useState } from 'react';
import { Modal, Platform, StyleSheet, View } from 'react-native';
import DateTimePicker, { DateTimePickerEvent } from '@react-native-community/datetimepicker';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const INITIAL = new Date(Date.UTC(2026, 0, 15));

function formatUTC(d: Date): string {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export function DatePickerScreen() {
  const [show, setShow] = useState(false);
  const [tempDate, setTempDate] = useState(INITIAL);
  const [result, setResult] = useState('date=none');

  const open = () => {
    setTempDate(INITIAL);
    setShow(true);
  };

  // Android は DatePickerDialog(ネイティブダイアログ)がそのまま出て、OK/キャンセルは
  // OS 標準ボタン(#btn_date_ok 等の testID は付けられない。ラベルはロケール依存の
  // システム文言 = 契約のダイアログ内部と同じ「ラベルで指す」前提)。
  const onChangeAndroid = (event: DateTimePickerEvent, date?: Date) => {
    setShow(false);
    if (event.type === 'set' && date) {
      setResult(`date=${formatUTC(date)}`);
    } else {
      setResult('date=cancel');
    }
  };

  return (
    <ScreenContainer>
      <TaggedButton testID={Tags.btnOpenDate} label="日付を選ぶ" onPress={open} />
      <EchoText testID={Tags.txtDateResult}>{result}</EchoText>

      {Platform.OS === 'android' && show && (
        <DateTimePicker value={tempDate} mode="date" display="default" onChange={onChangeAndroid} />
      )}

      {Platform.OS === 'ios' && (
        <Modal visible={show} transparent animationType="fade" onRequestClose={() => setShow(false)}>
          <View style={styles.backdrop}>
            <View style={styles.box}>
              <DateTimePicker
                value={tempDate}
                mode="date"
                display="inline"
                onChange={(_e, date) => date && setTempDate(date)}
              />
              <View style={styles.row}>
                <TaggedButton
                  testID={Tags.btnDateCancel}
                  label="キャンセル"
                  onPress={() => {
                    setShow(false);
                    setResult('date=cancel');
                  }}
                />
                <TaggedButton
                  testID={Tags.btnDateOk}
                  label="OK"
                  onPress={() => {
                    setShow(false);
                    setResult(`date=${formatUTC(tempDate)}`);
                  }}
                />
              </View>
            </View>
          </View>
        </Modal>
      )}
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.4)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  box: {
    backgroundColor: '#ffffff',
    borderRadius: 8,
    padding: 16,
    gap: 12,
  },
  row: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: 12,
  },
});
