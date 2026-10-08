import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../tags.dart';
import '../widgets.dart';

class HideBarsScreen extends StatefulWidget {
  const HideBarsScreen({super.key});

  @override
  State<HideBarsScreen> createState() => _HideBarsScreenState();
}

class _HideBarsScreenState extends State<HideBarsScreen> {
  static const _barHeight = 56.0;
  static const _anim = Duration(milliseconds: 200);

  String _result = 'none';
  bool _hidden = false;
  String _barsAtStop = 'shown';

  // reverse = 内容が上へ動く(下へ送る)→ 隠す。forward = 上へ送り返す → 出す。idle は無視
  bool _onUserScroll(UserScrollNotification n) {
    if (n.direction == ScrollDirection.reverse && !_hidden)
      setState(() => _hidden = true);
    if (n.direction == ScrollDirection.forward && _hidden)
      setState(() => _hidden = false);
    return false;
  }

  bool _onScrollEnd(ScrollEndNotification n) {
    final v = _hidden ? 'hidden' : 'shown';
    if (v != _barsAtStop) setState(() => _barsAtStop = v);
    return false;
  }

  void _set(String v) => setState(() => _result = v);

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: 'スクロールで隠れるバー',
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TaggedText(Tags.hideResult, 'hide=$_result'),
                TaggedText(Tags.barsState, 'bars=$_barsAtStop'),
              ],
            ),
          ),
        ),
        // **ClipRect が要る**: Stack がクリップするのはレイアウトのはみ出しだけで、AnimatedSlide(描画の段の平行移動)で
        // 上へ逃げたバーは Stack の外 = 隠れない固定領域(#txt_bars_state)の上に描かれていた(契約 A10 違反)
        Expanded(
          child: ClipRect(
            child: Stack(
              children: [
                NotificationListener<UserScrollNotification>(
                  onNotification: _onUserScroll,
                  child: NotificationListener<ScrollEndNotification>(
                    onNotification: _onScrollEnd,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: _barHeight),
                      itemCount: Tags.hideRowCount,
                      itemBuilder: (context, i) => tagged(
                        Tags.rowH(i),
                        ListTile(
                          title: Text(Tags.rowHLabel(i)),
                          onTap: () => _set(Tags.rowH(i)),
                        ),
                        button: true,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedSlide(
                    offset: _hidden ? const Offset(0, -1) : Offset.zero,
                    duration: _anim,
                    child: taggedContainer(
                      Tags.barTop,
                      Material(
                        elevation: 2,
                        child: SizedBox(
                          height: _barHeight,
                          child: Row(
                            children: [
                              const SizedBox(width: 16),
                              const Expanded(
                                child: Text(
                                  '受信トレイ',
                                  style: TextStyle(fontSize: 18),
                                ),
                              ),
                              TextButton(
                                onPressed: () => _set('top_action'),
                                child: tagged(
                                  Tags.btnTopAction,
                                  const Text('並べ替え'),
                                  button: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: _barHeight + 16,
                  child: AnimatedSlide(
                    offset: _hidden ? const Offset(0, 4) : Offset.zero,
                    duration: _anim,
                    child: tagged(
                      Tags.fabHiding,
                      FloatingActionButton(
                        heroTag: null,
                        tooltip: '作成',
                        onPressed: () => _set('fab'),
                        child: const Icon(Icons.edit),
                      ),
                      button: true,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedSlide(
                    offset: _hidden ? const Offset(0, 1) : Offset.zero,
                    duration: _anim,
                    child: taggedContainer(
                      Tags.barBottom,
                      Material(
                        elevation: 2,
                        child: SizedBox(
                          height: _barHeight,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              TextButton(
                                onPressed: () => _set('bottom_a'),
                                child: tagged(
                                  Tags.btnBottomA,
                                  const Text('受信'),
                                  button: true,
                                ),
                              ),
                              TextButton(
                                onPressed: () => _set('bottom_b'),
                                child: tagged(
                                  Tags.btnBottomB,
                                  const Text('フォルダ'),
                                  button: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
