package com.ftester.e2ex.flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // #native_label の PlatformView 用ファクトリ。Dart 側は lib/screens/native_screen.dart の
        // AndroidView(viewType: "native_label_view") から参照する
        // (E2EXAppCMP/docs/ui-contract-wave2.md §固有部品)。
        flutterEngine.platformViewsController.registry
            .registerViewFactory("native_label_view", NativeLabelViewFactory())
    }
}
