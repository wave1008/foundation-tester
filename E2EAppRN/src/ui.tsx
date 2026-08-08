import React, { useRef } from 'react';
import {
  GestureResponderEvent,
  Modal,
  Pressable,
  ScrollView,
  StyleProp,
  StyleSheet,
  Switch,
  Text,
  TextStyle,
  View,
  ViewStyle,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Tags } from './tags';

export type AppTab = 'home' | 'controls' | 'about';

// ボタンは Pressable + accessible + accessibilityRole="button" + testID +
// accessibilityLabel(表示文字列と同値)。disabled でも a11y ツリーから消さない
// (enabled=false はツリーに残したまま accessibilityState.disabled だけで表現する)。
export function TaggedButton({
  testID,
  label,
  onPress,
  disabled = false,
  fillWidth = false,
  style,
}: {
  testID?: string;
  label: string;
  onPress: () => void;
  disabled?: boolean;
  fillWidth?: boolean;
  style?: StyleProp<ViewStyle>;
}) {
  return (
    <Pressable
      testID={testID}
      accessible
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={[
        styles.button,
        fillWidth && styles.buttonFillWidth,
        disabled && styles.buttonDisabled,
        style,
      ]}
    >
      {/* 内側 Text を a11y から隠す(Android は accessible={true} でも子ノードが
          別に出て button と同ラベルの staticText が並び、素のラベルセレクタが
          曖昧になる。iOS も XCUITest が間欠的に子を別ノードで出す。実測 2026-08-08) */}
      <Text
        style={styles.buttonLabel}
        importantForAccessibility="no-hide-descendants"
        accessibilityElementsHidden
      >
        {label}
      </Text>
    </Pressable>
  );
}

/** 状態表示("key=value")用の素の Text。ラベル文字列以外の意味は持たせない。 */
export function EchoText({
  testID,
  style,
  children,
}: {
  testID: string;
  style?: StyleProp<TextStyle>;
  children: string;
}) {
  return (
    <Text testID={testID} style={style}>
      {children}
    </Text>
  );
}

/** 画面本体の共通コンテナ。scrollable=false はソフトキーボード対策(入力画面)に使う。 */
export function ScreenContainer({
  children,
  scrollable = true,
  style,
}: {
  children: React.ReactNode;
  scrollable?: boolean;
  style?: StyleProp<ViewStyle>;
}) {
  if (!scrollable) {
    return <View style={[styles.screenColumn, style]}>{children}</View>;
  }
  return (
    <ScrollView contentContainerStyle={[styles.screenColumn, style]}>
      {children}
    </ScrollView>
  );
}

/** ラベル Text とコントロール本体を別要素にする行(ラベル自体はタップ対象にしない)。 */
export function LabeledRow({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <View style={styles.labeledRow}>
      <Text>{label}</Text>
      {children}
    </View>
  );
}

export function TaggedSwitch({
  testID,
  value,
  onValueChange,
  accessibilityLabel,
}: {
  testID?: string;
  value: boolean;
  onValueChange: (v: boolean) => void;
  accessibilityLabel?: string;
}) {
  return (
    <Switch
      testID={testID}
      value={value}
      onValueChange={onValueChange}
      accessibilityLabel={accessibilityLabel}
    />
  );
}

/** Checkbox/Radio は RN 標準部品が無いため Pressable 自前実装。ラベルは別要素側が持つため
 * ここでは accessibilityLabel を付けない(#id で指す契約)。 */
export function TaggedCheckbox({
  testID,
  checked,
  onToggle,
}: {
  testID: string;
  checked: boolean;
  onToggle: (v: boolean) => void;
}) {
  return (
    <Pressable
      testID={testID}
      accessible
      accessibilityRole="checkbox"
      accessibilityState={{ checked }}
      onPress={() => onToggle(!checked)}
      style={styles.checkboxTouchTarget}
    >
      <View style={[styles.checkboxBox, checked && styles.checkboxBoxChecked]} />
    </Pressable>
  );
}

export function TaggedRadio({
  testID,
  selected,
  onSelect,
}: {
  testID: string;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <Pressable
      testID={testID}
      accessible
      accessibilityRole="radio"
      accessibilityState={{ checked: selected }}
      onPress={onSelect}
      style={styles.radioTouchTarget}
    >
      <View style={[styles.radioOuter, selected && styles.radioOuterSelected]}>
        {selected && <View style={styles.radioInner} />}
      </View>
    </Pressable>
  );
}

/** ネイティブ依存を避けた自前スライダー。シナリオは volume=50 の echo しか見ないため簡素でよい。 */
export function TaggedSlider({
  testID,
  value,
  min = 0,
  max = 100,
  step = 25,
  onChange,
}: {
  testID: string;
  value: number;
  min?: number;
  max?: number;
  step?: number;
  onChange: (v: number) => void;
}) {
  const widthRef = useRef(200);

  const applyTouch = (locationX: number) => {
    const ratio = Math.min(1, Math.max(0, locationX / widthRef.current));
    const raw = min + ratio * (max - min);
    const stepped = Math.round(raw / step) * step;
    onChange(Math.min(max, Math.max(min, stepped)));
  };

  return (
    <View
      testID={testID}
      accessible
      accessibilityRole="adjustable"
      accessibilityValue={{ min, max, now: value }}
      onLayout={e => {
        widthRef.current = e.nativeEvent.layout.width || widthRef.current;
      }}
      onStartShouldSetResponder={() => true}
      onMoveShouldSetResponder={() => true}
      onResponderGrant={(e: GestureResponderEvent) => applyTouch(e.nativeEvent.locationX)}
      onResponderMove={(e: GestureResponderEvent) => applyTouch(e.nativeEvent.locationX)}
      style={styles.sliderTrack}
    >
      <View
        style={[
          styles.sliderFill,
          { width: `${((value - min) / (max - min)) * 100}%` },
        ]}
      />
    </View>
  );
}

/** ダイアログは Modal(transparent)に隔離する(後で非 Modal のオーバーレイに差し替え可能な形)。
 * onRequestClose は Android の back キーの受け口(渡さないと back でダイアログが閉じない)。 */
export function DialogOverlay({
  visible,
  onRequestClose,
  children,
}: {
  visible: boolean;
  onRequestClose: () => void;
  children: React.ReactNode;
}) {
  return (
    <Modal
      visible={visible}
      transparent
      animationType="fade"
      statusBarTranslucent
      onRequestClose={onRequestClose}
    >
      <View style={styles.dialogBackdrop}>
        <View style={styles.dialogBox}>{children}</View>
      </View>
    </Modal>
  );
}

/** 全画面共通シェル: タイトル → 戻る(ルート以外) → コンテンツ → 下部タブ3つ、の順に並べる。
 * この JSX 順が a11y ツリー順(= セレクタ画面の序数)を決めるので崩さないこと。 */
export function ScreenShell({
  title,
  showBack,
  onBack,
  activeTab,
  onTabChange,
  children,
}: {
  title: string;
  showBack: boolean;
  onBack: () => void;
  activeTab: AppTab;
  onTabChange: (tab: AppTab) => void;
  children: React.ReactNode;
}) {
  return (
    <SafeAreaView style={styles.shell} edges={['top', 'left', 'right', 'bottom']}>
      <Text testID={Tags.screenTitle} style={styles.title}>
        {title}
      </Text>
      {showBack && (
        <TaggedButton testID={Tags.back} label="戻る" onPress={onBack} style={styles.backButton} />
      )}
      <View style={styles.content}>{children}</View>
      <View style={styles.tabBar}>
        <TaggedButton
          testID={Tags.tabHome}
          label="ホーム"
          fillWidth
          onPress={() => onTabChange('home')}
          style={[styles.tabButton, activeTab === 'home' && styles.tabButtonActive]}
        />
        <TaggedButton
          testID={Tags.tabControls}
          label="コントロール"
          fillWidth
          onPress={() => onTabChange('controls')}
          style={[styles.tabButton, activeTab === 'controls' && styles.tabButtonActive]}
        />
        <TaggedButton
          testID={Tags.tabAbout}
          label="情報"
          fillWidth
          onPress={() => onTabChange('about')}
          style={[styles.tabButton, activeTab === 'about' && styles.tabButtonActive]}
        />
      </View>
    </SafeAreaView>
  );
}

export const styles = StyleSheet.create({
  shell: {
    flex: 1,
    backgroundColor: '#ffffff',
  },
  title: {
    fontSize: 20,
    fontWeight: '600',
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 4,
  },
  backButton: {
    alignSelf: 'flex-start',
    marginHorizontal: 16,
    marginBottom: 4,
  },
  content: {
    flex: 1,
  },
  tabBar: {
    flexDirection: 'row',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: '#cccccc',
  },
  tabButton: {
    flex: 1,
    borderRadius: 0,
  },
  tabButtonActive: {
    backgroundColor: '#d0dcff',
  },
  screenColumn: {
    padding: 16,
    gap: 8,
  },
  button: {
    minHeight: 48,
    paddingHorizontal: 16,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#e6e6e6',
    borderRadius: 6,
  },
  buttonFillWidth: {
    alignSelf: 'stretch',
  },
  buttonDisabled: {
    opacity: 0.4,
  },
  buttonLabel: {
    fontSize: 16,
  },
  labeledRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    minHeight: 48,
  },
  checkboxTouchTarget: {
    minWidth: 44,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  checkboxBox: {
    width: 24,
    height: 24,
    borderWidth: 2,
    borderColor: '#666666',
    borderRadius: 4,
  },
  checkboxBoxChecked: {
    backgroundColor: '#3366ff',
    borderColor: '#3366ff',
  },
  radioTouchTarget: {
    minWidth: 44,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  radioOuter: {
    width: 24,
    height: 24,
    borderRadius: 12,
    borderWidth: 2,
    borderColor: '#666666',
    alignItems: 'center',
    justifyContent: 'center',
  },
  radioOuterSelected: {
    borderColor: '#3366ff',
  },
  radioInner: {
    width: 12,
    height: 12,
    borderRadius: 6,
    backgroundColor: '#3366ff',
  },
  sliderTrack: {
    height: 44,
    justifyContent: 'center',
    backgroundColor: '#e6e6e6',
    borderRadius: 6,
    overflow: 'hidden',
  },
  sliderFill: {
    height: '100%',
    backgroundColor: '#3366ff',
  },
  dialogBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.4)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  dialogBox: {
    minWidth: 260,
    backgroundColor: '#ffffff',
    borderRadius: 8,
    padding: 16,
    gap: 12,
  },
});
