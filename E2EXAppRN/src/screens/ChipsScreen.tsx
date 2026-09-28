import React, { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import Slider from '@react-native-community/slider';
import { Chip, SegmentedButtons } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

export function ChipsScreen() {
  const [wifi, setWifi] = useState(false);
  const [assistResult, setAssistResult] = useState('assist=none');
  const [seg, setSeg] = useState('day');
  const [rangeMin, setRangeMin] = useState(20);
  const [rangeMax, setRangeMax] = useState(80);

  return (
    <ScreenContainer>
      <Chip testID={Tags.chipWifi} selected={wifi} mode="flat" onPress={() => setWifi(w => !w)}>
        Wi-Fi
      </Chip>
      <EchoText testID={Tags.txtChipResult}>{`wifi=${wifi}`}</EchoText>

      <Chip
        testID={Tags.chipAssist}
        mode="outlined"
        onPress={() => setAssistResult('assist=tapped')}
      >
        ヘルプ
      </Chip>
      <EchoText testID={Tags.txtAssistResult}>{assistResult}</EchoText>

      <SegmentedButtons
        value={seg}
        onValueChange={setSeg}
        buttons={[
          { value: 'day', label: '日', testID: Tags.segDay },
          { value: 'week', label: '週', testID: Tags.segWeek },
          { value: 'month', label: '月', testID: Tags.segMonth },
        ]}
      />
      <EchoText testID={Tags.txtSegResult}>{`seg=${seg}`}</EchoText>

      {/*
        CMP の RangeSlider(単一部品・両端つまみ)に対応する保守された RN 部品が New Architecture 前提で
        見当たらなかった(@react-native-community/slider は単一つまみのみ)ため、min/max 2本の
        Slider で代替する(#range_slider は両者を束ねる箱として残す)。値は整数に丸めて
        min<=max を維持する。
      */}
      <View testID={Tags.rangeSlider} style={styles.rangeBox}>
        <Slider
          testID={Tags.rangeSliderMin}
          minimumValue={0}
          maximumValue={100}
          value={rangeMin}
          onValueChange={v => setRangeMin(Math.min(Math.round(v), rangeMax))}
        />
        <Slider
          testID={Tags.rangeSliderMax}
          minimumValue={0}
          maximumValue={100}
          value={rangeMax}
          onValueChange={v => setRangeMax(Math.max(Math.round(v), rangeMin))}
        />
      </View>
      <EchoText testID={Tags.txtRangeResult}>{`range=${rangeMin}-${rangeMax}`}</EchoText>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  rangeBox: {
    gap: 4,
  },
});
