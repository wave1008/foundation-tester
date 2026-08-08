import React, { useEffect, useRef, useState } from 'react';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

type DelayState = 'idle' | 'waiting' | 'done';

export function AsyncScreen() {
  const [state, setState] = useState<DelayState>('idle');
  const [showDelayed, setShowDelayed] = useState(false);
  const [countdown, setCountdown] = useState<number | null>(null);
  const timersRef = useRef<Array<ReturnType<typeof setTimeout>>>([]);

  // 前回タイマを消さないと、古い遅延が後から done を書き込んで検証を壊す。
  const cancelTimers = () => {
    timersRef.current.forEach(clearTimeout);
    timersRef.current = [];
  };

  useEffect(() => cancelTimers, []);

  const startDelay = (seconds: number, withCountdown: boolean) => {
    cancelTimers();
    setState('waiting');
    setShowDelayed(false);
    setCountdown(withCountdown ? seconds : null);
    if (withCountdown) {
      for (let n = seconds - 1; n >= 0; n--) {
        const t = setTimeout(() => setCountdown(n), (seconds - n) * 1000);
        timersRef.current.push(t);
      }
    }
    const done = setTimeout(() => {
      setState('done');
      setShowDelayed(true);
    }, seconds * 1000);
    timersRef.current.push(done);
  };

  const reset = () => {
    cancelTimers();
    setState('idle');
    setShowDelayed(false);
    setCountdown(null);
  };

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtDelayState}>{`state=${state}`}</EchoText>
      <TaggedButton testID={Tags.btnDelay1} label="1秒後に表示" onPress={() => startDelay(1, false)} />
      <TaggedButton testID={Tags.btnDelay3} label="3秒後に表示" onPress={() => startDelay(3, true)} />
      <TaggedButton testID={Tags.btnDelay8} label="8秒後に表示" onPress={() => startDelay(8, false)} />
      {/* 待機中はツリーに置かない(非表示ではなく未配置であることが検証点) */}
      {showDelayed && <EchoText testID={Tags.txtDelayed}>遅延表示 完了</EchoText>}
      {countdown !== null && <EchoText testID={Tags.txtCountdown}>{`count=${countdown}`}</EchoText>}
      <TaggedButton testID={Tags.btnAsyncReset} label="非同期リセット" onPress={reset} />
    </ScreenContainer>
  );
}
