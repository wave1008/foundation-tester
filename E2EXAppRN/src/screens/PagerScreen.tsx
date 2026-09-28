import React, { useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import PagerView from 'react-native-pager-view';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const PAGE_COUNT = 5;

export function PagerScreen() {
  const pagerRef = useRef<PagerView>(null);
  const [page, setPage] = useState(0);
  const [result, setResult] = useState('pager=none');

  const goNext = () => {
    if (page < PAGE_COUNT - 1) {
      pagerRef.current?.setPage(page + 1);
    }
  };

  return (
    <ScreenContainer>
      <PagerView
        ref={pagerRef}
        testID={Tags.pagerMain}
        style={styles.pager}
        initialPage={0}
        onPageSelected={e => setPage(e.nativeEvent.position)}
      >
        {Array.from({ length: PAGE_COUNT }, (_, n) => (
          <View key={n} style={styles.page}>
            <EchoText testID={Tags.txtPage(n)}>{`ページ ${n}`}</EchoText>
            <TaggedButton
              testID={Tags.btnPage(n)}
              label={`ページ ${n} のボタン`}
              onPress={() => setResult(`pager=tapped ${n}`)}
            />
          </View>
        ))}
      </PagerView>
      <EchoText testID={Tags.txtPagerState}>{`page=${page}`}</EchoText>
      <EchoText testID={Tags.txtPagerResult}>{result}</EchoText>
      <TaggedButton testID={Tags.btnPagerNext} label="次のページ" onPress={goNext} />
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  pager: {
    height: 240,
    alignSelf: 'stretch',
  },
  page: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
  },
});
