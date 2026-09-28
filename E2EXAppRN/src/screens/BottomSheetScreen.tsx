import React, { useCallback, useMemo, useRef, useState } from 'react';
import { StyleSheet } from 'react-native';
import { BottomSheetBackdrop, BottomSheetFlatList, BottomSheetModal } from '@gorhom/bottom-sheet';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const ROWS = Array.from({ length: 30 }, (_, n) => n);

export function BottomSheetScreen() {
  const sheetRef = useRef<BottomSheetModal>(null);
  const [result, setResult] = useState('sheet=none');
  // gorhom/bottom-sheet の onChange(index === -1) はスクリム・下スワイプ・戻る「だけでなく」
  // dismiss() 呼び出し経由の close でも発火する。選択肢/行タップの close は結果を先に確定させたいので
  // このフラグで「意図した close」を区別し、dismissed で上書きしない。
  const explicitCloseRef = useRef(false);

  const closeWith = (value: string) => {
    explicitCloseRef.current = true;
    setResult(value);
    sheetRef.current?.dismiss();
  };

  const handleSheetChange = useCallback((index: number) => {
    if (index === -1) {
      if (!explicitCloseRef.current) {
        setResult('sheet=dismissed');
      }
      explicitCloseRef.current = false;
    }
  }, []);

  const backdrop = useCallback(
    (props: React.ComponentProps<typeof BottomSheetBackdrop>) => (
      <BottomSheetBackdrop {...props} appearsOnIndex={0} disappearsOnIndex={-1} />
    ),
    [],
  );

  const snapPoints = useMemo(() => ['60%'], []);

  const header = (
    <>
      <EchoText testID={Tags.txtSheetTitle} style={styles.sheetTitle}>
        シートの見出し
      </EchoText>
      {[1, 2, 3].map(n => (
        <TaggedButton
          key={n}
          testID={Tags.btnSheetOpt(n)}
          label={`選択肢 ${n}`}
          onPress={() => closeWith(`sheet=opt${n}`)}
        />
      ))}
    </>
  );

  return (
    <ScreenContainer>
      <TaggedButton
        testID={Tags.btnOpenSheet}
        label="シートを開く"
        onPress={() => sheetRef.current?.present()}
      />
      <EchoText testID={Tags.txtSheetResult}>{result}</EchoText>
      <BottomSheetModal
        ref={sheetRef}
        snapPoints={snapPoints}
        backdropComponent={backdrop}
        onChange={handleSheetChange}
        // 既定の accessible=true は中身全体を role="adjustable"(iOS では slider)の
        // 単一要素へ畳み込み、見出し・行・ボタンが木から消える(iOS だけ。Android は畳まない)。
        accessible={false}
      >
        <BottomSheetFlatList
          testID="list_sheet"
          data={ROWS}
          keyExtractor={n => String(n)}
          ListHeaderComponent={header}
          renderItem={({ item }) => (
            <TaggedButton
              testID={Tags.rowSheet(item)}
              label={`シート行 ${String(item).padStart(2, '0')}`}
              onPress={() => closeWith(`sheet=row${String(item).padStart(2, '0')}`)}
            />
          )}
        />
      </BottomSheetModal>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  sheetTitle: {
    fontSize: 16,
    fontWeight: '600',
    paddingHorizontal: 16,
  },
});
