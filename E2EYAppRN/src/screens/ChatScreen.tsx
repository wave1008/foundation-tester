import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  FlatList,
  KeyboardAvoidingView,
  NativeScrollEvent,
  NativeSyntheticEvent,
  Platform,
  StyleSheet,
  TextInput,
  View,
} from 'react-native';
import { useHeaderHeight } from '@react-navigation/elements';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

type Msg = { id: number; label: string };

// 新しいものが先頭(inverted の index 0 = 最下部)。
const INITIAL: Msg[] = Array.from({ length: 60 }, (_, k) => {
  const id = 59 - k;
  return { id, label: `メッセージ ${String(id).padStart(2, '0')}` };
});

const AWAY_THRESHOLD = 80;
const SETTLE_MS = 200;
const INCOMING_DELAY_MS = 1000;

export function ChatScreen() {
  const headerHeight = useHeaderHeight();
  const listRef = useRef<FlatList<Msg>>(null);
  const [messages, setMessages] = useState<Msg[]>(INITIAL);
  const [result, setResult] = useState('chat=none');
  const [atBottomEcho, setAtBottomEcho] = useState(true);
  const [away, setAway] = useState(false);
  const [draft, setDraft] = useState('');
  const nextId = useRef(60);
  const atBottomRef = useRef(true);
  const settleTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const incomingTimers = useRef<Array<ReturnType<typeof setTimeout>>>([]);

  useEffect(
    () => () => {
      if (settleTimer.current) clearTimeout(settleTimer.current);
      incomingTimers.current.forEach(clearTimeout);
    },
    [],
  );

  const onScroll = useCallback((e: NativeSyntheticEvent<NativeScrollEvent>) => {
    // inverted: contentOffset.y = 0 が最下部(最新)
    const y = e.nativeEvent.contentOffset.y;
    atBottomRef.current = y <= 20;
    setAway(y > AWAY_THRESHOLD);
    if (settleTimer.current) clearTimeout(settleTimer.current);
    settleTimer.current = setTimeout(() => setAtBottomEcho(atBottomRef.current), SETTLE_MS);
  }, []);

  const scrollToBottom = (animated: boolean) => listRef.current?.scrollToOffset({ offset: 0, animated });

  const send = () => {
    if (draft === '') return;
    const id = nextId.current++;
    setMessages(prev => [{ id, label: draft }, ...prev]);
    setDraft('');
    setTimeout(() => scrollToBottom(true), 0);
  };

  const incoming = () => {
    const t = setTimeout(() => {
      const id = nextId.current++;
      const follow = atBottomRef.current;
      setMessages(prev => [{ id, label: `着信 ${String(id).padStart(2, '0')}` }, ...prev]);
      if (follow) setTimeout(() => scrollToBottom(true), 0);
    }, INCOMING_DELAY_MS);
    incomingTimers.current.push(t);
  };

  return (
    <KeyboardAvoidingView
      style={styles.root}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={headerHeight}
    >
      <View style={styles.echo}>
        <EchoText testID={Tags.txtChatResult}>{result}</EchoText>
        <EchoText testID={Tags.txtChatCount}>{`count=${messages.length}`}</EchoText>
        <EchoText testID={Tags.txtChatPos}>{`at_bottom=${atBottomEcho}`}</EchoText>
        <TaggedButton testID={Tags.btnIncoming} label="着信" onPress={incoming} />
      </View>
      <View style={styles.listWrap}>
        <FlatList
          ref={listRef}
          testID={Tags.listChat}
          inverted
          data={messages}
          keyExtractor={m => String(m.id)}
          scrollEventThrottle={16}
          onScroll={onScroll}
          // 最下部付近なら追従・離れていれば位置を保つ(index 0 は新着なので数えない)
          maintainVisibleContentPosition={{ minIndexForVisible: 1, autoscrollToTopThreshold: 10 }}
          renderItem={({ item }) => (
            <TaggedButton
              testID={Tags.msg(item.id)}
              label={item.label}
              onPress={() => setResult(`chat=${Tags.msg(item.id)}`)}
              style={styles.msg}
            />
          )}
        />
        {away && (
          <TaggedButton
            testID={Tags.btnJumpBottom}
            label="最新へ"
            onPress={() => scrollToBottom(true)}
            style={styles.jump}
          />
        )}
      </View>
      <View style={styles.inputBar}>
        <TextInput
          testID={Tags.fieldChat}
          style={styles.input}
          placeholder="メッセージを入力"
          value={draft}
          onChangeText={setDraft}
        />
        <TaggedButton testID={Tags.btnSend} label="送信" onPress={send} />
      </View>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#ffffff' },
  echo: { padding: 8, gap: 2 },
  listWrap: { flex: 1 },
  msg: { height: 56, marginVertical: 2, marginHorizontal: 8, alignItems: 'flex-start' },
  jump: { position: 'absolute', right: 12, bottom: 12 },
  inputBar: { flexDirection: 'row', alignItems: 'center', gap: 8, padding: 8 },
  input: {
    flex: 1,
    minHeight: 44,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#999999',
    borderRadius: 6,
    paddingHorizontal: 8,
  },
});
