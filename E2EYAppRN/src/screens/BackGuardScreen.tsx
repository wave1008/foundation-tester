import React, { useEffect, useRef, useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';
import { useFocusEffect, usePreventRemove } from '@react-navigation/native';
import type { NavigationAction } from '@react-navigation/native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';

import type { RootStackParamList } from '../navigation';
import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

// 編集画面 → 元の画面へ結果を渡す(画面離脱で捨てる)。
const backStore = { value: 'back=none' };

export function BackGuardScreen({ navigation }: NativeStackScreenProps<RootStackParamList, 'BackGuard'>) {
  const [result, setResult] = useState('back=none');
  useFocusEffect(
    React.useCallback(() => {
      setResult(backStore.value);
    }, []),
  );
  useEffect(
    () => () => {
      backStore.value = 'back=none';
    },
    [],
  );
  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtBackResult}>{result}</EchoText>
      <TaggedButton
        testID={Tags.btnOpenEditor}
        label="編集画面を開く"
        onPress={() => navigation.navigate('Editor')}
      />
    </ScreenContainer>
  );
}

export function EditorScreen({ navigation }: NativeStackScreenProps<RootStackParamList, 'Editor'>) {
  const [title, setTitle] = useState('');
  const [panelOpen, setPanelOpen] = useState(false);
  const [confirming, setConfirming] = useState(false);

  // パネルが開いている or 欄に文字がある間は戻りを横取りする(native-stack はこの間エッジスワイプも止める)
  const prevent = panelOpen || title !== '';
  const preventRef = useRef(prevent);
  preventRef.current = prevent;

  // 破棄は横取りした action をそのまま流す(別の goBack() は再び横取りされる)
  const pendingRef = useRef<NavigationAction | null>(null);
  usePreventRemove(prevent, ({ data }) => {
    if (panelOpen) {
      setPanelOpen(false);
    } else {
      pendingRef.current = data.action;
      setConfirming(true);
    }
  });

  // 横取りしない戻り = 欄が空・パネル閉 → back=clean。破棄はダイアログ側で値を入れる
  useEffect(
    () =>
      navigation.addListener('beforeRemove', () => {
        if (!preventRef.current) backStore.value = 'back=clean';
      }),
    [navigation],
  );

  return (
    <ScreenContainer>
      <TextInput
        testID={Tags.fieldTitle}
        accessibilityLabel="タイトル"
        placeholder="タイトル"
        style={styles.input}
        value={title}
        onChangeText={setTitle}
      />
      <EchoText testID={Tags.txtEditorState}>{`panel=${panelOpen ? 'open' : 'closed'}`}</EchoText>
      <TaggedButton testID={Tags.btnOpenPanel} label="パネルを開く" onPress={() => setPanelOpen(true)} />
      {panelOpen && (
        <View testID={Tags.panelInline} style={styles.panel}>
          <EchoText testID={Tags.txtPanel}>パネル</EchoText>
        </View>
      )}
      {confirming && (
        // Alert は testID を通せないので画面内のオーバーレイで確認を出す
        <View style={styles.overlay} accessibilityViewIsModal>
          <View style={styles.dialog}>
            <EchoText testID={Tags.txtDiscardTitle}>変更を破棄しますか?</EchoText>
            <TaggedButton
              testID={Tags.btnDiscard}
              label="破棄"
              onPress={() => {
                backStore.value = 'back=discarded';
                if (pendingRef.current) navigation.dispatch(pendingRef.current);
              }}
            />
            <TaggedButton testID={Tags.btnKeep} label="編集を続ける" onPress={() => setConfirming(false)} />
          </View>
        </View>
      )}
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  input: {
    minHeight: 44,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#999999',
    borderRadius: 6,
    paddingHorizontal: 8,
  },
  panel: { padding: 16, backgroundColor: '#eef2ff', borderRadius: 6 },
  overlay: {
    position: "absolute", top: 0, left: 0, right: 0, bottom: 0,
    backgroundColor: 'rgba(0,0,0,0.4)',
    justifyContent: 'center',
    padding: 24,
  },
  dialog: { backgroundColor: '#ffffff', borderRadius: 10, padding: 16, gap: 8 },
});
