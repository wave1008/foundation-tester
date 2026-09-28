import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tags.dart';
import '../widgets.dart';

/// Hero 元画面(この画面)と HeroDetailScreen で共有する tag。
const heroTag = 'e2ex-native-hero';

class NativeScreen extends StatefulWidget {
  const NativeScreen({super.key});

  @override
  State<NativeScreen> createState() => _NativeScreenState();
}

class _NativeScreenState extends State<NativeScreen> {
  String _result = 'none';
  bool _cupertinoSwitch = false;

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '固有部品',
        body: ScreenColumn(children: [
          TaggedText(Tags.nativeResult, 'native=$_result'),
          Row(
            children: [
              Hero(
                tag: heroTag,
                child: Container(
                  width: 48,
                  height: 48,
                  color: Colors.indigo,
                  alignment: Alignment.center,
                  child: const Icon(Icons.auto_awesome, color: Colors.white),
                ),
              ),
              const SizedBox(width: 16),
              TaggedButton(Tags.btnHero, 'Hero で開く', onTap: () {
                setState(() => _result = 'hero:opened');
                context.push('/native/hero');
              }),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              const Text('Cupertino スイッチ'),
              const Spacer(),
              tagged(
                Tags.swCupertino,
                CupertinoSwitch(
                  value: _cupertinoSwitch,
                  onChanged: (v) => setState(() {
                    _cupertinoSwitch = v;
                    _result = 'cupertino_switch:${v ? 'on' : 'off'}';
                  }),
                ),
                button: true,
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Cupertino ピッカー'),
          SizedBox(
            height: 120,
            child: taggedContainer(
              Tags.pickerCupertino,
              CupertinoPicker(
                itemExtent: 32,
                onSelectedItemChanged: (index) => setState(
                    () => _result = 'cupertino_picker:${Tags.cupertinoPickerItems[index]}'),
                children: [
                  for (final item in Tags.cupertinoPickerItems) Center(child: Text(item)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text('PlatformView(ネイティブのラベル)'),
          SizedBox(
            height: 48,
            child: taggedContainer(Tags.nativeLabel, const _NativeLabelView()),
          ),
          const SizedBox(height: 8),
          TaggedButton(
            Tags.btnPlatformViewSeen,
            'ネイティブビューを確認',
            onTap: () => setState(() => _result = 'platform_view:shown'),
          ),
        ]),
      );
}

/// iOS = `UiKitView` / Android = `AndroidView`。ネイティブ側のビューファクトリ登録
/// (view type `native_label_view`)は ios/Runner/AppDelegate.swift と
/// android/app/src/main/kotlin/.../MainActivity.kt(E2EXAppCMP/docs/ui-contract-wave2.md §固有部品)。
class _NativeLabelView extends StatelessWidget {
  const _NativeLabelView();

  static const _viewType = 'native_label_view';

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return const AndroidView(viewType: _viewType);
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const UiKitView(viewType: _viewType);
    }
    return const SizedBox.shrink();
  }
}
