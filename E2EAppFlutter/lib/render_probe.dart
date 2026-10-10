import 'dart:io';

import 'package:flutter/scheduler.dart';

/// 計測用の描画プローブ(一時ディレクトリに render-probe.on があるときだけ動く。iOS = アプリの tmp・
/// Android = アプリの cache = `adb shell run-as <pkg> touch cache/render-probe.on`)。
/// Flutter は画面が変わるときだけフレームを作るので、addPersistentFrameCallback(フレームごとに1回)の時刻 =
/// 描き直した時刻。壁時計の ms(小数3桁)を render-probe.log へ1行ずつ書く(ホストが時計の差を補正する)。
/// 同等品: E2EAppIOS/Sources/Util/RenderProbe.swift(iOS のレイヤー木)・E2EAppAndroid の RenderProbe.kt(View の描画)
class RenderProbe {
  static RandomAccessFile? _log;

  /// Android のアプリのプロセス名(= パッケージ名)。/proc/self/cmdline の最初の NUL まで。読めなければ null
  static String? _androidPackageName() {
    try {
      final name = File('/proc/self/cmdline').readAsStringSync().split('\u0000').first.trim();
      return name.isEmpty ? null : name;
    } catch (_) {
      return null;
    }
  }

  static void startIfRequested() {
    // Android の systemTemp はアプリの cache ではない(run-as で置いた目印が見えなかった)ので cache も候補にする。
    // パッケージ名は自分のプロセス名から取る(決め打ちにしない)
    final candidates = [
      Directory.systemTemp.path,
      if (Platform.isAndroid) ...[
        for (final pkg in [_androidPackageName()])
          if (pkg != null) '/data/user/0/$pkg/cache',
      ],
    ];
    final dir = candidates.firstWhere((d) => File('$d/render-probe.on').existsSync(), orElse: () => '');
    if (dir.isEmpty) return;
    // 目印は読んだら消す(次の起動の1回だけ効く)。残すと以後の普段の起動・E2E でもフレームごとに書き続ける
    File('$dir/render-probe.on').deleteSync();
    _log = File('$dir/render-probe.log').openSync(mode: FileMode.write);
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      final ms = DateTime.now().microsecondsSinceEpoch / 1000.0;
      _log?.writeStringSync('${ms.toStringAsFixed(3)}\n');
    });
  }
}
