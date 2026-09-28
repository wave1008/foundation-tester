import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class DatePickerScreen extends StatefulWidget {
  const DatePickerScreen({super.key});

  @override
  State<DatePickerScreen> createState() => _DatePickerScreenState();
}

class _DatePickerScreenState extends State<DatePickerScreen> {
  String _result = 'none';

  Future<void> _open() async {
    // showDatePicker の OK/Cancel は組み込みダイアログボタンで id を付けられない
    // (契約どおりラベル "OK"/"Cancel" で指す前提。docs/ui-contract.md 参照)。
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(2026, 1, 15),
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2030, 12, 31),
    );
    // Flutter の DatePicker は選択を null に戻す UI を持たない(常に日付が選ばれた状態で OK
    // される)。null が返るのはキャンセル/バリアタップだけなので date=null には到達しない
    // (CMP 契約の date=null はここでは再現できない。docs/ui-contract.md の逸脱として記載)。
    setState(() => _result = picked == null ? 'cancel' : _format(picked));
  }

  String _format(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '日付ピッカー',
        body: ScreenColumn(children: [
          TaggedText(Tags.dateResult, 'date=$_result'),
          TaggedButton(Tags.btnOpenDate, '日付を選ぶ', onTap: _open),
        ]),
      );
}
