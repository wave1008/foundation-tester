import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class TimeScreen extends StatefulWidget {
  const TimeScreen({super.key});

  @override
  State<TimeScreen> createState() => _TimeScreenState();
}

class _TimeScreenState extends State<TimeScreen> {
  String _result = 'none';

  Future<void> _open() async {
    // showTimePicker の OK/Cancel は組み込みダイアログボタンで id を付けられない
    // (showDatePicker と同じ制約。既定の英語ローカライズの "OK"/"Cancel" ラベルで指す前提。
    // docs/ui-contract.md に記載。#btn_time_ok/#btn_time_cancel は宣言のみで未使用)。
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 30),
      initialEntryMode: TimePickerEntryMode.dial,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    setState(() => _result = picked == null ? 'cancel' : _format(picked));
  }

  String _format(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '時刻ピッカー',
        body: ScreenColumn(children: [
          TaggedText(Tags.timeResult, 'time=$_result'),
          TaggedButton(Tags.btnOpenTime, '時刻を選ぶ', onTap: _open),
        ]),
      );
}
