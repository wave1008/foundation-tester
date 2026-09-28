import React, { useRef, useState } from 'react';
import { KeyboardAvoidingView, Platform, ScrollView, StyleSheet, View } from 'react-native';
import { TextInput } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ListRow, ScreenContainer } from '../ui';

const COUNTRIES = [
  { testID: Tags.autoOpt('japan'), value: 'Japan' },
  { testID: Tags.autoOpt('jamaica'), value: 'Jamaica' },
  { testID: Tags.autoOpt('jordan'), value: 'Jordan' },
];

export function InputsScreen() {
  const [number, setNumber] = useState('');
  const [password, setPassword] = useState('');
  const [multiline, setMultiline] = useState('');
  const [first, setFirst] = useState('');
  const [second, setSecond] = useState('');
  const [focusEcho, setFocusEcho] = useState('focus=none');
  const [auto, setAuto] = useState('');
  const [autoResult, setAutoResult] = useState('auto=none');
  const [bottom, setBottom] = useState('');

  // paper TextInput の ref 型は RN TextInput 側の ref 型と交差してしまい素直に型付けできないため
  // any で受ける(実体には .focus() が生える。paper 自身の内部実装もこの前提で書かれている)。
  const secondRef = useRef<{ focus: () => void } | null>(null);

  const suggestions = COUNTRIES.filter(
    c => auto.length > 0 && c.value.toLowerCase().startsWith(auto.toLowerCase()),
  );

  return (
    <ScreenContainer style={styles.screen}>
      {/* echo は全部この固定領域にまとめる(スクロールせず・キーボードにも隠れない)。
          欄はこの下のスクロール領域に置く(コーディネータの指示: echo と欄の領域を分ける)。 */}
      <View style={styles.echoArea}>
        <EchoText testID={Tags.txtNumberEcho}>{`number=${number}`}</EchoText>
        <EchoText testID={Tags.txtPasswordEcho}>{`password_len=${password.length}`}</EchoText>
        <EchoText testID={Tags.txtMultilineEcho}>
          {`lines=${multiline.length === 0 ? 0 : multiline.split('\n').length}`}
        </EchoText>
        <EchoText testID={Tags.txtFocusEcho}>{focusEcho}</EchoText>
        <EchoText testID={Tags.txtAutoEcho}>{autoResult}</EchoText>
        <EchoText testID={Tags.txtBottomEcho}>{`bottom=${bottom}`}</EchoText>
      </View>

      <KeyboardAvoidingView
        style={styles.fieldsArea}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <ScrollView
          contentContainerStyle={styles.fieldsContent}
          keyboardShouldPersistTaps="handled"
        >
          <TextInput
            testID={Tags.fieldNumber}
            label="数量"
            keyboardType="number-pad"
            value={number}
            onChangeText={setNumber}
          />
          <TextInput
            testID={Tags.fieldPassword}
            label="パスワード"
            secureTextEntry
            value={password}
            onChangeText={setPassword}
          />
          <TextInput
            testID={Tags.fieldMultiline}
            label="メモ"
            multiline
            numberOfLines={3}
            value={multiline}
            onChangeText={setMultiline}
          />
          <TextInput
            testID={Tags.fieldFirst}
            label="姓"
            value={first}
            onChangeText={setFirst}
            returnKeyType="next"
            onSubmitEditing={() => secondRef.current?.focus()}
          />
          <TextInput
            testID={Tags.fieldSecond}
            ref={(instance: any) => {
              secondRef.current = instance;
            }}
            label="名"
            value={second}
            onChangeText={setSecond}
            onFocus={() => setFocusEcho('focus=second')}
          />
          <TextInput
            testID={Tags.fieldAuto}
            label="国"
            value={auto}
            onChangeText={t => {
              setAuto(t);
              setAutoResult('auto=none');
            }}
            // 候補は英字国名の前方一致。日本語ロケール端末の既定キーボードはローマ字入力を
            // 変換候補にするため、素の TextInput のままだと "Ja" のような入力が変換で
            // 別の文字(仮名)に化けうる。英字専用の入力であることを明示して素通しの
            // 英字キーボードにし、自動変換・自動大文字化もオフにする。
            autoCorrect={false}
            autoCapitalize="none"
            keyboardType={Platform.OS === 'ios' ? 'ascii-capable' : 'default'}
          />
          {suggestions.map(c => (
            <ListRow
              key={c.testID}
              testID={c.testID}
              label={c.value}
              onPress={() => {
                setAuto(c.value);
                setAutoResult(`auto=${c.value}`);
              }}
            />
          ))}

          {/* 画面下端(キーボードに隠れる位置)。上の echo 領域を固定にした分、この欄は
              スクロール領域の下いっぱいへ押し出す。 */}
          <View style={styles.bottomFieldSpacer}>
            <TextInput
              testID={Tags.fieldBottom}
              label="下の欄"
              value={bottom}
              onChangeText={setBottom}
            />
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  screen: {
    gap: 0,
  },
  echoArea: {
    gap: 4,
    paddingBottom: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#cccccc',
  },
  fieldsArea: {
    flex: 1,
  },
  fieldsContent: {
    flexGrow: 1,
    paddingTop: 12,
    gap: 8,
  },
  bottomFieldSpacer: {
    marginTop: 'auto',
  },
});
