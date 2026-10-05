import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as mui show DefaultMaterialLocalizations, Material, MaterialType;
import 'package:pinput/pinput.dart';

import '../tags.dart';
import '../widgets.dart';

class PinScreen extends StatefulWidget {
  const PinScreen({super.key});

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  static const _otpLength = 6;
  static const _pinLength = 4;

  final _otp = TextEditingController();
  final _otpFocus = FocusNode();
  String _otpResult = 'none';
  String _pinResult = 'none';
  String _pin = '';
  Timer? _submit;

  @override
  void dispose() {
    _submit?.cancel();
    _otp.dispose();
    _otpFocus.dispose();
    super.dispose();
  }

  // 6 桁そろったら 0.3 秒後に自動送信して箱を空へ戻す
  void _onOtpCompleted(String value) {
    _submit?.cancel();
    _submit = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _otpResult = value);
      _otp.clear();
    });
  }

  void _press(String digit) {
    if (_pin.length >= _pinLength) return;
    setState(() {
      _pin += digit;
      if (_pin.length == _pinLength) {
        _pinResult = _pin;
        _pin = '';
      }
    });
  }

  void _delete() => setState(() {
    if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
  });

  Widget _box(PinItemState s) => tagged(
    Tags.otpBox(s.index + 1),
    Container(
      width: 44,
      height: 52,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(
          color: s.type == PinItemStateType.focused ? Colors.blue : Colors.grey,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(s.value, style: const TextStyle(fontSize: 22)),
    ),
  );

  Widget _key(String tag, Widget label, VoidCallback onTap) => SizedBox(
    width: 72,
    height: 44,
    child: tagged(
      tag,
      ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(padding: EdgeInsets.zero),
        child: label,
      ),
      button: true,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final dots = '●' * _pin.length;
    return FtScaffold(
      title: 'PIN と OTP',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TaggedText(Tags.otpResult, 'otp=$_otpResult'),
            TaggedText(Tags.pinResult, 'pin=$_pinResult'),
            TaggedText(Tags.pinLen, 'pin_len=${_pin.length}'),
            const SizedBox(height: 16),
            // 実体は隠れた入力欄 1 つ(Pinput)。箱は表示だけ
            taggedContainer(
              Tags.fieldOtp,
              // Pinput は material_ui パッケージの Material と MaterialLocalizations を要求する
              // (flutter/material.dart の同名の型とは別物で、Scaffold・MaterialApp では満たされない)
              Localizations.override(
                context: context,
                delegates: const [mui.DefaultMaterialLocalizations.delegate],
                child: mui.Material(
                  type: mui.MaterialType.transparency,
                  child: Pinput.builder(
                    length: _otpLength,
                    controller: _otp,
                    focusNode: _otpFocus,
                    keyboardType: TextInputType.number,
                    onCompleted: _onOtpCompleted,
                    builder: (context, s) => _box(s),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Center(child: TaggedText(Tags.pinDots, dots)),
            const SizedBox(height: 8),
            Center(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final d in [1, 2, 3, 4, 5, 6, 7, 8, 9])
                    _key(Tags.key(d), Text('$d'), () {
                      _press('$d');
                    }),
                  const SizedBox(width: 72),
                  _key(Tags.key(0), const Text('0'), () {
                    _press('0');
                  }),
                  _key(
                    Tags.keyDel,
                    const Icon(Icons.backspace_outlined, semanticLabel: '削除'),
                    _delete,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
