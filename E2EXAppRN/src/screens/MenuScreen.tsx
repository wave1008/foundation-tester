import React, { useEffect, useState } from 'react';
import { BackHandler, Pressable, View } from 'react-native';
import { Menu, TextInput } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const FRUITS: Array<{ testID: string; key: string; label: string }> = [
  { testID: Tags.optFruitApple, key: 'apple', label: 'りんご' },
  { testID: Tags.optFruitBanana, key: 'banana', label: 'バナナ' },
  { testID: Tags.optFruitCherry, key: 'cherry', label: 'さくらんぼ' },
];

export function MenuScreen() {
  const [menuVisible, setMenuVisible] = useState(false);
  const [menuResult, setMenuResult] = useState('menu=none');

  const [fruitMenuVisible, setFruitMenuVisible] = useState(false);
  const [fruitLabel, setFruitLabel] = useState('');
  const [fruitResult, setFruitResult] = useState('fruit=none');

  const selectMenuItem = (key: string) => {
    setMenuResult(`menu=${key}`);
    setMenuVisible(false);
  };

  // paper の Menu 自身も hardwareBackPress を購読するが、onDismiss() の戻り値を返さない
  // (true を返さないと「消費した」と扱われず react-navigation の戻る処理へ伝播し、画面ごと
  // 戻ってしまう)。Menu より後にマウントされる本 effect が購読順で先に呼ばれるので、
  // ここで消費してから閉じる。
  useEffect(() => {
    if (!menuVisible) return undefined;
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      setMenuVisible(false);
      setMenuResult('menu=dismissed');
      return true;
    });
    return () => sub.remove();
  }, [menuVisible]);

  const selectFruit = (key: string, label: string) => {
    setFruitLabel(label);
    setFruitResult(`fruit=${key}`);
    setFruitMenuVisible(false);
  };

  return (
    <ScreenContainer>
      <Menu
        visible={menuVisible}
        onDismiss={() => {
          setMenuVisible(false);
          setMenuResult('menu=dismissed');
        }}
        anchor={
          <TaggedButton
            testID={Tags.btnOpenMenu}
            label="メニューを開く"
            onPress={() => setMenuVisible(true)}
          />
        }
      >
        <Menu.Item testID={Tags.menuItemCopy} title="コピー" onPress={() => selectMenuItem('copy')} />
        <Menu.Item testID={Tags.menuItemShare} title="共有" onPress={() => selectMenuItem('share')} />
        <Menu.Item
          testID={Tags.menuItemDelete}
          title="削除"
          onPress={() => selectMenuItem('delete')}
        />
      </Menu>
      <EchoText testID={Tags.txtMenuResult}>{menuResult}</EchoText>

      <Menu
        visible={fruitMenuVisible}
        onDismiss={() => setFruitMenuVisible(false)}
        anchor={
          <Pressable onPress={() => setFruitMenuVisible(true)}>
            {/* pointerEvents="none" の下(タップを外側の Pressable へ通すため)は iOS だと
                「非対話の親の下は個々の子を数えず親ごと畳む」対象になり、TextInput 自身に
                付けた testID/値は木から消える(Android は消えない)。id/ラベル/現在値は
                この View 自身を accessible にして乗せる。 */}
            <View
              pointerEvents="none"
              accessible
              testID={Tags.fieldFruit}
              accessibilityLabel="果物"
              accessibilityValue={{ text: fruitLabel }}
            >
              <TextInput label="果物" value={fruitLabel} editable={false} />
            </View>
          </Pressable>
        }
      >
        {FRUITS.map(f => (
          <Menu.Item
            key={f.key}
            testID={f.testID}
            title={f.label}
            onPress={() => selectFruit(f.key, f.label)}
          />
        ))}
      </Menu>
      <EchoText testID={Tags.txtFruitResult}>{fruitResult}</EchoText>
    </ScreenContainer>
  );
}
