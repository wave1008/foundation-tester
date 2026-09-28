import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class ChipsScreen extends StatefulWidget {
  const ChipsScreen({super.key});

  @override
  State<ChipsScreen> createState() => _ChipsScreenState();
}

class _ChipsScreenState extends State<ChipsScreen> {
  bool _wifi = false;
  String _assist = 'none';
  String _seg = 'day';
  RangeValues _range = const RangeValues(20, 80);

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'チップと分割ボタン',
        body: ScreenColumn(children: [
          tagged(
            Tags.chipWifi,
            FilterChip(label: const Text('Wi-Fi'), selected: _wifi, onSelected: (v) => setState(() => _wifi = v)),
            button: true,
          ),
          TaggedText(Tags.chipResult, 'wifi=$_wifi'),
          tagged(
            Tags.chipAssist,
            ActionChip(label: const Text('ヘルプ'), onPressed: () => setState(() => _assist = 'tapped')),
            button: true,
          ),
          TaggedText(Tags.assistResult, 'assist=$_assist'),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'day', label: tagged(Tags.segDay, const Text('日'), button: true)),
              ButtonSegment(value: 'week', label: tagged(Tags.segWeek, const Text('週'), button: true)),
              ButtonSegment(value: 'month', label: tagged(Tags.segMonth, const Text('月'), button: true)),
            ],
            selected: {_seg},
            onSelectionChanged: (s) => setState(() => _seg = s.first),
          ),
          TaggedText(Tags.segResult, 'seg=$_seg'),
          // Slider と同じ罠(MergeSemantics で畳むと iOS の a11y ツリーが全滅する)が
          // RangeSlider にもある可能性があるため、予防的に単体 Semantics で包む(未検証)。
          Semantics(
            identifier: Tags.rangeSlider,
            child: RangeSlider(
              values: _range,
              min: 0,
              max: 100,
              onChanged: (v) => setState(() => _range = v),
            ),
          ),
          TaggedText(Tags.rangeResult, 'range=${_range.start.round()}-${_range.end.round()}'),
        ]),
      );
}
