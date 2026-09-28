import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class ZoomScreen extends StatefulWidget {
  const ZoomScreen({super.key});

  @override
  State<ZoomScreen> createState() => _ZoomScreenState();
}

class _ZoomScreenState extends State<ZoomScreen> {
  final _controller = TransformationController();
  double _scale = 1.0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _updateScale() {
    final scale = _controller.value.getMaxScaleOnAxis();
    setState(() => _scale = double.parse(scale.toStringAsFixed(1)));
  }

  void _reset() {
    _controller.value = Matrix4.identity();
    setState(() => _scale = 1.0);
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'ピンチで拡大',
        body: ScreenColumn(children: [
          TaggedText(Tags.zoomScale, 'scale=${_scale.toStringAsFixed(1)}'),
          TaggedButton(Tags.btnZoomReset, '元に戻す', onTap: _reset),
          // #zoom_target の枠(SizedBox)ではみ出しを切り取る(拡大した中身が上の echo を
          // 覆わないように。InteractiveViewer は clipBehavior 既定 Clip.hardEdge で自枠に
          // 収まるが、枠自体も ClipRect で二重に保証する)。
          ClipRect(
            child: SizedBox(
              height: 300,
              child: taggedContainer(
                Tags.zoomTarget,
                InteractiveViewer(
                  transformationController: _controller,
                  clipBehavior: Clip.hardEdge,
                  minScale: 1,
                  maxScale: 4,
                  onInteractionUpdate: (_) => _updateScale(),
                  onInteractionEnd: (_) => _updateScale(),
                  child: Container(
                    color: Colors.blueGrey.shade100,
                    alignment: Alignment.center,
                    child: const Icon(Icons.image, size: 96),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
}
