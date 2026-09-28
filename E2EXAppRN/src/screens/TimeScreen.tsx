import React, { useState } from 'react';
import { Modal, Platform, StyleSheet, View } from 'react-native';
import DateTimePicker, { DateTimePickerEvent } from '@react-native-community/datetimepicker';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

function initialTime(): Date {
  const d = new Date();
  d.setHours(9, 30, 0, 0);
  return d;
}

function formatTime(d: Date): string {
  const h = String(d.getHours()).padStart(2, '0');
  const m = String(d.getMinutes()).padStart(2, '0');
  return `${h}:${m}`;
}

export function TimeScreen() {
  const [show, setShow] = useState(false);
  const [tempTime, setTempTime] = useState(initialTime);
  const [result, setResult] = useState('time=none');

  const open = () => {
    setTempTime(initialTime());
    setShow(true);
  };

  // Android は TimePickerDialog(ネイティブ)がそのまま出る。契約の「入力モードへの切替口」は
  // ダイアログ既定の時計/キーボード切替アイコンで満たされる(自前実装不要)。OK/キャンセルは
  // OS 標準ボタンで testID を通せない(日付ピッカーと同じ制約)。
  const onChangeAndroid = (event: DateTimePickerEvent, date?: Date) => {
    setShow(false);
    if (event.type === 'set' && date) {
      setResult(`time=${formatTime(date)}`);
    } else {
      setResult('time=cancel');
    }
  };

  return (
    <ScreenContainer>
      <TaggedButton testID={Tags.btnOpenTime} label="時刻を選ぶ" onPress={open} />
      <EchoText testID={Tags.txtTimeResult}>{result}</EchoText>

      {Platform.OS === 'android' && show && (
        <DateTimePicker
          value={tempTime}
          mode="time"
          is24Hour
          display="default"
          onChange={onChangeAndroid}
        />
      )}

      {/* iOS の spinner 表示には数字入力モードへの切替口が無い(既知の逸脱。docs に記録)。 */}
      {Platform.OS === 'ios' && (
        <Modal visible={show} transparent animationType="fade" onRequestClose={() => setShow(false)}>
          <View style={styles.backdrop}>
            <View style={styles.box}>
              <DateTimePicker
                value={tempTime}
                mode="time"
                is24Hour
                display="spinner"
                onChange={(_e, date) => date && setTempTime(date)}
              />
              <View style={styles.row}>
                <TaggedButton
                  testID={Tags.btnTimeCancel}
                  label="キャンセル"
                  onPress={() => {
                    setShow(false);
                    setResult('time=cancel');
                  }}
                />
                <TaggedButton
                  testID={Tags.btnTimeOk}
                  label="OK"
                  onPress={() => {
                    setShow(false);
                    setResult(`time=${formatTime(tempTime)}`);
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
