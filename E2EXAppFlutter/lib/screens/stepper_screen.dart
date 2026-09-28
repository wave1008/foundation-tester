import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class StepperScreen extends StatefulWidget {
  const StepperScreen({super.key});

  @override
  State<StepperScreen> createState() => _StepperScreenState();
}

class _StepperScreenState extends State<StepperScreen> with SingleTickerProviderStateMixin {
  int _qty = 1;
  String _progressState = 'idle';
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..addListener(() => setState(() {}))
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) setState(() => _progressState = 'done');
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _startProgress() {
    setState(() => _progressState = 'running');
    _controller
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'ステッパーと進捗',
        body: ScreenColumn(children: [
          taggedContainer(
            Tags.stepperQty,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                tagged(
                  Tags.btnQtyMinus,
                  IconButton(
                    icon: const Icon(Icons.remove),
                    tooltip: '減らす',
                    onPressed: _qty > 0 ? () => setState(() => _qty -= 1) : null,
                  ),
                  button: true,
                ),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('$_qty')),
                tagged(
                  Tags.btnQtyPlus,
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: '増やす',
                    onPressed: _qty < 10 ? () => setState(() => _qty += 1) : null,
                  ),
                  button: true,
                ),
              ],
            ),
          ),
          TaggedText(Tags.txtQty, 'qty=$_qty'),
          const SizedBox(height: 16),
          TaggedButton(
            Tags.btnStartProgress,
            '進捗を開始',
            onTap: _startProgress,
            enabled: _progressState != 'running',
          ),
          taggedContainer(Tags.progressMain, LinearProgressIndicator(value: _controller.value)),
          TaggedText(Tags.txtProgress, 'progress=$_progressState'),
          if (_progressState == 'running')
            taggedContainer(Tags.spinnerBusy, const CircularProgressIndicator()),
        ]),
      );
}
