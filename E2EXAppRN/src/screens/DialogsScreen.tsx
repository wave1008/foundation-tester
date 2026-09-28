import React, { useRef, useState } from 'react';
import { ActionSheetIOS, Alert, Modal, Platform, StyleSheet, ToastAndroid } from 'react-native';
import { Button, Dialog, List, Portal, TextInput } from 'react-native-paper';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

export function DialogsScreen() {
  const [result, setResult] = useState('dialogs=none');
  const [promptVisible, setPromptVisible] = useState(false);
  const [promptValue, setPromptValue] = useState('');
  const [sheetVisible, setSheetVisible] = useState(false);
  const [fullscreenVisible, setFullscreenVisible] = useState(false);
  // paper Dialog の onDismiss はスクリム・戻る操作**以外**(自分で visible=false にした場合)でも
  // 発火しうるため、ボタン操作で確定済みの結果を上書きしないためのフラグ。
  const explicitCloseRef = useRef(false);

  const showAlert = () => {
    Alert.alert('確認', undefined, [
      { text: 'キャンセル', style: 'cancel', onPress: () => setResult('alert=cancel') },
      { text: 'OK', onPress: () => setResult('alert=ok') },
    ]);
  };

  const openPrompt = () => {
    setPromptValue('');
    setPromptVisible(true);
  };
  const closePrompt = (value: string) => {
    explicitCloseRef.current = true;
    setPromptVisible(false);
    setResult(value);
  };
  const onDismissPrompt = () => {
    setPromptVisible(false);
    if (!explicitCloseRef.current) {
      setResult('prompt=cancel');
    }
    explicitCloseRef.current = false;
  };

  const showActionSheet = () => {
    if (Platform.OS === 'ios') {
      // Alert.prompt と違い ActionSheetIOS は iOS 専用 API(core)。契約どおり iOS だけこれを使う。
      ActionSheetIOS.showActionSheetWithOptions(
        { options: ['写真を撮る', 'ライブラリから選ぶ', 'キャンセル'], cancelButtonIndex: 2 },
        buttonIndex => {
          if (buttonIndex === 0) setResult('sheet=camera');
          else if (buttonIndex === 1) setResult('sheet=library');
          else setResult('sheet=cancel');
        },
      );
    } else {
      setSheetVisible(true);
    }
  };
  const closeSheet = (value: string) => {
    explicitCloseRef.current = true;
    setSheetVisible(false);
    setResult(value);
  };
  const onDismissSheet = () => {
    setSheetVisible(false);
    if (!explicitCloseRef.current) {
      setResult('sheet=cancel');
    }
    explicitCloseRef.current = false;
  };

  return (
    <ScreenContainer>
      <TaggedButton testID={Tags.btnAlert} label="アラート" onPress={showAlert} />
      <TaggedButton testID={Tags.btnPrompt} label="入力つき" onPress={openPrompt} />
      <TaggedButton testID={Tags.btnActionSheet} label="アクションシート" onPress={showActionSheet} />
      <TaggedButton
        testID={Tags.btnFullscreen}
        label="全画面"
        onPress={() => setFullscreenVisible(true)}
      />
      {/* トーストは Android の core ToastAndroid だけが定番(iOS に対応する core API が無い)。 */}
      {Platform.OS === 'android' && (
        <TaggedButton
          testID={Tags.btnToast}
          label="トースト"
          onPress={() => {
            ToastAndroid.show('保存しました', ToastAndroid.SHORT);
            setResult('toast=shown');
          }}
        />
      )}
      <EchoText testID={Tags.txtDialogsResult}>{result}</EchoText>

      <Portal>
        <Dialog visible={promptVisible} onDismiss={onDismissPrompt}>
          <Dialog.Content>
            <TextInput testID={Tags.fieldPrompt} value={promptValue} onChangeText={setPromptValue} />
          </Dialog.Content>
          <Dialog.Actions>
            <Button onPress={() => closePrompt('prompt=cancel')}>キャンセル</Button>
            <Button onPress={() => closePrompt(`prompt=${promptValue}`)}>保存</Button>
          </Dialog.Actions>
        </Dialog>

        {/* Android にはネイティブの action sheet が無いため paper の Dialog + List で代替(契約が許容)。 */}
        <Dialog visible={sheetVisible} onDismiss={onDismissSheet}>
          <Dialog.Content>
            <List.Item title="写真を撮る" onPress={() => closeSheet('sheet=camera')} />
            <List.Item title="ライブラリから選ぶ" onPress={() => closeSheet('sheet=library')} />
            <List.Item title="キャンセル" onPress={() => closeSheet('sheet=cancel')} />
          </Dialog.Content>
        </Dialog>
      </Portal>

      <Modal
        visible={fullscreenVisible}
        presentationStyle="fullScreen"
        animationType="slide"
        onRequestClose={() => {
          setFullscreenVisible(false);
          setResult('fullscreen=closed');
        }}
      >
        {/* core Modal は react-navigation の画面と違い、自分ではセーフエリアを避けない
            (Android は特に、ステータスバーの真下からコンテンツが始まり先頭の要素と重なる。
            重なった部分は木からも消える)。SafeAreaView で自前に避ける。 */}
        <SafeAreaView style={styles.fullscreenModal}>
          <ScreenContainer>
            <EchoText testID={Tags.txtFullscreenTitle}>全画面ダイアログ</EchoText>
            <TaggedButton
              testID={Tags.btnFullscreenSave}
              label="保存"
              onPress={() => {
                setFullscreenVisible(false);
                setResult('fullscreen=saved');
              }}
            />
            <TaggedButton
              testID={Tags.btnFullscreenClose}
              label="閉じる"
              onPress={() => {
                setFullscreenVisible(false);
                setResult('fullscreen=closed');
              }}
            />
          </ScreenContainer>
        </SafeAreaView>
      </Modal>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  fullscreenModal: {
    flex: 1,
  },
});
