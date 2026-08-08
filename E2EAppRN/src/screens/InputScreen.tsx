import React, { useState } from 'react';
import { TextInput, View } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

// レイアウトはソフトキーボードに支配される(契約参照)。スクロールさせず、シナリオが触る要素
// (echo 3本 + submitted + 単一行/パスワード欄 + 送信/クリア)を画面上部(約384pt)に固める。
// 複数行欄とその echo だけは下でよい(シナリオが触らない)。
export function InputScreen() {
  const [single, setSingle] = useState('');
  const [password, setPassword] = useState('');
  const [multiline, setMultiline] = useState('');
  const [submitted, setSubmitted] = useState('-');
  const [imeCount, setImeCount] = useState(0);

  const clearAll = () => {
    setSingle('');
    setPassword('');
    setMultiline('');
    setSubmitted('-');
    setImeCount(0);
  };

  return (
    <ScreenContainer scrollable={false}>
      <EchoText testID={Tags.echoSingle}>{`single=${single}`}</EchoText>
      <EchoText testID={Tags.echoPassword}>{`password=${password}`}</EchoText>
      <EchoText testID={Tags.echoLength}>{`len=${single.length}`}</EchoText>
      <EchoText testID={Tags.imeAction}>{`ime=${imeCount}`}</EchoText>
      <EchoText testID={Tags.txtInputSubmitted}>{`submitted=${submitted}`}</EchoText>
      <TextInput
        testID={Tags.fieldSingle}
        accessibilityLabel="単一行"
        placeholder="単一行"
        value={single}
        onChangeText={setSingle}
        returnKeyType="search"
        // 改行は本文に入らない(singleLine 契約)。onSubmitEditing だけで発火回数を数える。
        onSubmitEditing={() => setImeCount(c => c + 1)}
        style={{ minHeight: 44, borderWidth: 1, borderColor: '#999999', padding: 8 }}
      />
      <TextInput
        testID={Tags.fieldPassword}
        accessibilityLabel="パスワード"
        placeholder="パスワード"
        value={password}
        onChangeText={setPassword}
        secureTextEntry
        style={{ minHeight: 44, borderWidth: 1, borderColor: '#999999', padding: 8 }}
      />
      <View style={{ flexDirection: 'row', gap: 8 }}>
        <TaggedButton
          testID={Tags.btnInputSubmit}
          label="送信"
          fillWidth
          onPress={() => setSubmitted(single)}
        />
        <TaggedButton testID={Tags.btnInputClear} label="入力クリア" fillWidth onPress={clearAll} />
      </View>
      <EchoText testID={Tags.echoMultiline}>{`multiline=${multiline.replace(/\n/g, ' ')}`}</EchoText>
      <TextInput
        testID={Tags.fieldMultiline}
        accessibilityLabel="複数行"
        placeholder="複数行"
        value={multiline}
        onChangeText={setMultiline}
        multiline
        numberOfLines={3}
        style={{ minHeight: 66, borderWidth: 1, borderColor: '#999999', padding: 8 }}
      />
    </ScreenContainer>
  );
}
