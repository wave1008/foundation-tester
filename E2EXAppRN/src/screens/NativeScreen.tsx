import React, { useState } from 'react';
import { Modal, StyleSheet, Switch, View } from 'react-native';
import { FlashList } from '@shopify/flash-list';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const FLASH_ROWS = Array.from({ length: 50 }, (_, n) => n);

export function NativeScreen() {
  const [result, setResult] = useState('native=none');
  const [modalVisible, setModalVisible] = useState(false);
  const [switchOn, setSwitchOn] = useState(false);

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtNativeResult}>{result}</EchoText>

      {/* @shopify/flash-list: RN 固有の高性能リスト部品(New Architecture 対応)。 */}
      <FlashList
        style={styles.flash}
        data={FLASH_ROWS}
        keyExtractor={n => String(n)}
        renderItem={({ item }) => (
          <TaggedButton
            testID={Tags.flashRow(item)}
            label={`行 ${String(item).padStart(2, '0')}`}
            onPress={() => setResult(`native=flash:${String(item).padStart(2, '0')}`)}
            style={styles.flashRow}
          />
        )}
      />

      <TaggedButton
        testID={Tags.btnModalOpen}
        label="モーダルを開く"
        onPress={() => setModalVisible(true)}
      />
      <Modal
        visible={modalVisible}
        transparent
        animationType="fade"
        onRequestClose={() => setModalVisible(false)}
      >
        <View style={styles.backdrop}>
          <View style={styles.box}>
            <TaggedButton
              testID={Tags.btnModalOk}
              label="OK"
              onPress={() => {
                setModalVisible(false);
                setResult('native=modal:ok');
              }}
            />
          </View>
        </View>
      </Modal>

      <View style={styles.switchRow}>
        <Switch
          testID={Tags.swCore}
          value={switchOn}
          onValueChange={v => {
            setSwitchOn(v);
            setResult(`native=switch:${v ? 'on' : 'off'}`);
          }}
        />
      </View>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  flash: {
    flex: 1,
  },
  flashRow: {
    marginVertical: 2,
  },
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
  },
  switchRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
});
