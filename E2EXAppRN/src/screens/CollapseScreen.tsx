import React, { useState } from 'react';
import { StyleSheet } from 'react-native';
import Animated, {
  Extrapolation,
  interpolate,
  useAnimatedScrollHandler,
  useAnimatedStyle,
  useSharedValue,
} from 'react-native-reanimated';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

const ROW_COUNT = 50;
const ROWS = Array.from({ length: ROW_COUNT }, (_, n) => n);
const HEADER_MAX_HEIGHT = 120;
const HEADER_MIN_HEIGHT = 56;
const HEADER_SCROLL_DISTANCE = HEADER_MAX_HEIGHT - HEADER_MIN_HEIGHT;

export function CollapseScreen() {
  const [result, setResult] = useState('collapse=none');
  const scrollY = useSharedValue(0);

  const scrollHandler = useAnimatedScrollHandler(e => {
    scrollY.value = e.contentOffset.y;
  });

  const headerStyle = useAnimatedStyle(() => ({
    height: interpolate(
      scrollY.value,
      [0, HEADER_SCROLL_DISTANCE],
      [HEADER_MAX_HEIGHT, HEADER_MIN_HEIGHT],
      Extrapolation.CLAMP,
    ),
  }));

  const titleStyle = useAnimatedStyle(() => ({
    fontSize: interpolate(
      scrollY.value,
      [0, HEADER_SCROLL_DISTANCE],
      [28, 17],
      Extrapolation.CLAMP,
    ),
  }));

  return (
    <>
      <Animated.FlatList
        style={styles.list}
        contentContainerStyle={{ paddingTop: HEADER_MAX_HEIGHT }}
        data={ROWS}
        keyExtractor={n => String(n)}
        onScroll={scrollHandler}
        scrollEventThrottle={16}
        renderItem={({ item }) => (
          <TaggedButton
            testID={Tags.rowC(item)}
            label={`行 C${String(item).padStart(2, '0')}`}
            onPress={() => setResult(`collapse=${Tags.rowC(item)}`)}
            style={styles.row}
          />
        )}
      />
      {/* ヘッダを別レイヤーで上に重ねる(縮んでも #txt_collapse_result が木に残り続ける位置)。 */}
      <Animated.View style={[styles.header, headerStyle]}>
        <Animated.Text testID={Tags.txtCollapseHeader} style={[styles.title, titleStyle]}>
          大きな見出し
        </Animated.Text>
        <EchoText testID={Tags.txtCollapseResult}>{result}</EchoText>
      </Animated.View>
    </>
  );
}

const styles = StyleSheet.create({
  list: {
    flex: 1,
  },
  row: {
    marginHorizontal: 16,
    marginVertical: 2,
  },
  header: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    justifyContent: 'flex-end',
    paddingHorizontal: 16,
    paddingBottom: 8,
    backgroundColor: '#ffffff',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#cccccc',
  },
  title: {
    fontWeight: '700',
  },
});
