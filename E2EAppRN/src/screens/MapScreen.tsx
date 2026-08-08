import React, { useRef, useState } from 'react';
import { PanResponder, StyleSheet, Text, View } from 'react-native';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

/** 軸ごとの向き判定の不感帯(8px 未満は none。手ぶれを斜めと誤判定しないため)。 */
const PAN_THRESHOLD = 8;
/** 倍率の不感帯。ピンチ以外の操作で拾う微小な zoom を in/out と読まないため。 */
const ZOOM_DEAD_ZONE = 0.05;
/** これ未満の移動・これ未満の経過時間ならタップ(ピンチ/パンと区別する)。 */
const TAP_MOVE_THRESHOLD = 8;
const TAP_MAX_DURATION_MS = 300;
const DOUBLE_TAP_INTERVAL_MS = 350;

type Touch = { x: number; y: number };

function distance(a: Touch, b: Touch): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function centroid(touches: Touch[]): Touch {
  const x = touches.reduce((sum, t) => sum + t.x, 0) / touches.length;
  const y = touches.reduce((sum, t) => sum + t.y, 0) / touches.length;
  return { x, y };
}

// ジェスチャ画面と分けてあるのは、あちらの #pad_swipe が drag を方向判定に使う作りで、
// 同じ領域に変形ジェスチャ(ピンチ)を重ねるとどちらかが空振りするため。
// RN には Flutter の onScale 相当の合成ジェスチャが無いため、PanResponder の生の touches から
// 距離比(ピンチ)と重心移動(パン)を自前で計算する。値は全て累積(#btn_map_reset でのみ戻る)。
export function MapScreen() {
  const [zoom, setZoom] = useState(1);
  const [panX, setPanX] = useState(0);
  const [panY, setPanY] = useState(0);
  const [doubleCount, setDoubleCount] = useState(0);

  const lastDistanceRef = useRef<number | null>(null);
  const lastCentroidRef = useRef<Touch | null>(null);
  const gestureStartRef = useRef<{ time: number; touch: Touch } | null>(null);
  const lastTapRef = useRef<{ time: number; touch: Touch } | null>(null);

  const zoomDir = zoom > 1 + ZOOM_DEAD_ZONE ? 'in' : zoom < 1 - ZOOM_DEAD_ZONE ? 'out' : '-';
  const panH = Math.abs(panX) < PAN_THRESHOLD ? 'none' : panX < 0 ? 'left' : 'right';
  const panV = Math.abs(panY) < PAN_THRESHOLD ? 'none' : panY < 0 ? 'up' : 'down';
  const panLabel = Math.abs(panX) < PAN_THRESHOLD && Math.abs(panY) < PAN_THRESHOLD ? '-' : `${panH}-${panV}`;

  const reset = () => {
    setZoom(1);
    setPanX(0);
    setPanY(0);
    setDoubleCount(0);
  };

  const panResponder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderGrant: evt => {
        const touches: Touch[] = evt.nativeEvent.touches.map(t => ({
          x: t.pageX,
          y: t.pageY,
        }));
        const first = touches[0] ?? { x: evt.nativeEvent.pageX, y: evt.nativeEvent.pageY };
        gestureStartRef.current = { time: Date.now(), touch: first };
        lastCentroidRef.current = touches.length > 0 ? centroid(touches) : first;
        lastDistanceRef.current = touches.length >= 2 ? distance(touches[0], touches[1]) : null;
      },
      onPanResponderMove: evt => {
        const touches: Touch[] = evt.nativeEvent.touches.map(t => ({
          x: t.pageX,
          y: t.pageY,
        }));
        if (touches.length === 0) {
          return;
        }
        const c = centroid(touches);
        // 差分は updater の外で確定させる: updater は非同期に走るため、速いドラッグでは
        // release が先に ref を null にし、updater 内の ref 参照が落ちる(Release では
        // fatal = プロセス終了。2026-08-08 に in-app の斜めドラッグで実クラッシュ)
        const prev = lastCentroidRef.current;
        if (prev) {
          const dx = c.x - prev.x;
          const dy = c.y - prev.y;
          setPanX(x => x + dx);
          setPanY(y => y + dy);
        }
        lastCentroidRef.current = c;

        if (touches.length >= 2) {
          const d = distance(touches[0], touches[1]);
          if (lastDistanceRef.current && lastDistanceRef.current > 0) {
            const ratio = d / lastDistanceRef.current;
            setZoom(z => z * ratio);
          }
          lastDistanceRef.current = d;
        } else {
          lastDistanceRef.current = null;
        }
      },
      onPanResponderRelease: evt => {
        const start = gestureStartRef.current;
        const endTouch = { x: evt.nativeEvent.pageX, y: evt.nativeEvent.pageY };
        if (
          start &&
          Date.now() - start.time < TAP_MAX_DURATION_MS &&
          distance(start.touch, endTouch) < TAP_MOVE_THRESHOLD &&
          evt.nativeEvent.changedTouches.length === 1
        ) {
          const prevTap = lastTapRef.current;
          const now = Date.now();
          if (prevTap && now - prevTap.time < DOUBLE_TAP_INTERVAL_MS && distance(prevTap.touch, endTouch) < TAP_MOVE_THRESHOLD) {
            setDoubleCount(n => n + 1);
            lastTapRef.current = null;
          } else {
            lastTapRef.current = { time: now, touch: endTouch };
          }
        }
        gestureStartRef.current = null;
        lastDistanceRef.current = null;
        lastCentroidRef.current = null;
      },
    }),
  ).current;

  return (
    <View style={styles.root}>
      <View testID={Tags.padMap} style={[styles.pad, StyleSheet.absoluteFill]} {...panResponder.panHandlers}>
        <Text>マップ領域</Text>
      </View>
      <View style={styles.topRight}>
        <EchoText testID={Tags.txtZoomDir}>{`zoom=${zoomDir}`}</EchoText>
        <EchoText testID={Tags.txtZoom}>{`zoom=${zoom.toFixed(1)}`}</EchoText>
        <EchoText testID={Tags.txtPan}>{`pan=${panLabel}`}</EchoText>
        <EchoText testID={Tags.txtDoubleCount}>{`double=${doubleCount}`}</EchoText>
      </View>
      <View style={styles.bottomLeft}>
        <TaggedButton testID={Tags.btnMapReset} label="マップクリア" fillWidth onPress={reset} />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
  },
  pad: {
    backgroundColor: '#eeeeee',
    alignItems: 'center',
    justifyContent: 'center',
  },
  topRight: {
    position: 'absolute',
    top: 12,
    right: 12,
    width: '45%',
    gap: 8,
    alignItems: 'flex-end',
  },
  bottomLeft: {
    position: 'absolute',
    bottom: 12,
    left: 12,
    width: '45%',
  },
});
