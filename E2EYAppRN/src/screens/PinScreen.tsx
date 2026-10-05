import React, { useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const OTP_LEN = 6;
const PIN_LEN = 4;
const OTP_SUBMIT_DELAY_MS = 300;

export function PinScreen() {
  const [otp, setOtp] = useState('');
  const [otpResult, setOtpResult] = useState('otp=none');
  const [pin, setPin] = useState('');
  const [pinResult, setPinResult] = useState('pin=none');
  const inputRef = useRef<TextInput>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    [],
  );

  const onOtpChange = (raw: string) => {
    const v = raw.replace(/\D/g, '').slice(0, OTP_LEN);
    setOtp(v);
    if (v.length === OTP_LEN) {
      timer.current = setTimeout(() => {
        setOtpResult(`otp=${v}`);
        setOtp('');
      }, OTP_SUBMIT_DELAY_MS);
    }
  };

  const press = (d: string) => {
    if (pin.length >= PIN_LEN) return;
    const next = pin + d;
    if (next.length === PIN_LEN) {
      setPinResult(`pin=${next}`);
      setPin('');
    } else {
      setPin(next);
    }
  };

  const shown = pin.length === PIN_LEN ? '' : pin;
  const lenNow = pin.length;

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtOtpResult}>{otpResult}</EchoText>
      <EchoText testID={Tags.txtPinResult}>{pinResult}</EchoText>
      <EchoText testID={Tags.txtPinLen}>{`pin_len=${lenNow}`}</EchoText>

      <View style={styles.otpArea}>
        <View style={styles.boxes} pointerEvents="none">
          {Array.from({ length: OTP_LEN }, (_, k) => (
            <Text key={k} testID={Tags.otpBox(k + 1)} style={styles.box}>
              {otp[k] ?? ' '}
            </Text>
          ))}
        </View>
        {/* 実体は箱の上に重ねた透明の入力欄 1 つ(どの箱を押しても焦点が移る) */}
        <TextInput
          ref={inputRef}
          testID={Tags.fieldOtp}
          style={styles.hiddenInput}
          value={otp}
          onChangeText={onOtpChange}
          keyboardType="number-pad"
          maxLength={OTP_LEN}
          caretHidden
          accessibilityLabel="認証コード"
        />
      </View>

      <Text testID={Tags.pinDots} style={styles.dots}>
        {'●'.repeat(shown.length) || ' '}
      </Text>
      <View style={styles.pad}>
        {['1', '2', '3', '4', '5', '6', '7', '8', '9'].map(d => (
          <TaggedButton key={d} testID={Tags.key(Number(d))} label={d} onPress={() => press(d)} style={styles.key} />
        ))}
        <View style={styles.key} />
        <TaggedButton testID={Tags.key(0)} label="0" onPress={() => press('0')} style={styles.key} />
        <Pressable
          testID={Tags.keyDel}
          accessible
          accessibilityRole="button"
          accessibilityLabel="削除"
          onPress={() => setPin(p => p.slice(0, -1))}
          style={[styles.key, styles.keyDel]}
        >
          <Text importantForAccessibility="no-hide-descendants" accessibilityElementsHidden>
            ⌫
          </Text>
        </Pressable>
      </View>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  otpArea: { height: 52, marginVertical: 4 },
  boxes: { flexDirection: 'row', gap: 6, justifyContent: 'center' },
  box: {
    width: 44,
    height: 48,
    borderWidth: 1,
    borderColor: '#888888',
    borderRadius: 6,
    textAlign: 'center',
    textAlignVertical: 'center',
    lineHeight: 48,
    fontSize: 20,
  },
  hiddenInput: { position: "absolute", top: 0, left: 0, right: 0, bottom: 0, opacity: 0.02 },
  dots: { fontSize: 24, textAlign: 'center', height: 32 },
  pad: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', gap: 6 },
  key: { width: '30%', height: 48 },
  keyDel: { alignItems: 'center', justifyContent: 'center', backgroundColor: '#e6e6e6', borderRadius: 6 },
});
