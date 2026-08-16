package com.ftester.e2e.flutter

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * fte2eflutter:// を Dart へ渡す唯一の経路(MethodChannel。採用理由は
 * E2EAppFlutter/docs/ui-contract.md)。getInitialUrl は cold start の URL を Dart 側からの
 * pull で一度だけ返す。onNewUrl は singleTop 再利用時(onNewIntent)の push。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.ftester.e2e.flutter/deeplink"
    private var channel: MethodChannel? = null
    private var pendingInitialUrl: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingInitialUrl = intent?.data?.toString()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        ch.setMethodCallHandler { call, result ->
            if (call.method == "getInitialUrl") {
                result.success(pendingInitialUrl)
                pendingInitialUrl = null
            } else {
                result.notImplemented()
            }
        }
        channel = ch
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.data?.toString()?.let { url -> channel?.invokeMethod("onNewUrl", url) }
    }
}
