import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class AnimScreen extends StatefulWidget {
  const AnimScreen({super.key});

  @override
  State<AnimScreen> createState() => _AnimScreenState();
}

class _AnimScreenState extends State<AnimScreen> {
  bool _visible = false;
  int _count = 0;

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'アニメーション',
        body: ScreenColumn(children: [
          TaggedButton(Tags.btnToggleAnim, '表示を切り替える',
              onTap: () => setState(() => _visible = !_visible)),
          // ボタンを押した時点で切り替わる(アニメーション中から true。契約 §アニメーション)。
          TaggedText(Tags.animVisible, 'visible=$_visible'),
          // 常にツリーに残し、透明度だけ 1500ms で animate する(Compose の AnimatedVisibility は
          // 非表示化で composition から外すが、ここでは #txt_anim_target を常時マウントのまま
          // フェードだけ行う。docs/ui-contract.md の逸脱として記載)。
          AnimatedOpacity(
            duration: const Duration(milliseconds: 1500),
            opacity: _visible ? 1 : 0,
            child: const TaggedText(Tags.animTarget, 'アニメ完了'),
          ),
          const SizedBox(height: 16),
          TaggedButton(Tags.btnAnimInc, '増やす', onTap: () => setState(() => _count += 1)),
          tagged(
            Tags.animCount,
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 800),
              child: Text('count=$_count', key: ValueKey(_count)),
            ),
          ),
        ]),
      );
}
