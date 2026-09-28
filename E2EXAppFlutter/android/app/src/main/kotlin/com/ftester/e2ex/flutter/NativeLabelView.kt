package com.ftester.e2ex.flutter

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.TextView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class NativeLabelViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        NativeLabelPlatformView(context)
}

private class NativeLabelPlatformView(context: Context) : PlatformView {
    // シナリオはこの resource-id で参照する(#native_label。契約どおり。id 資源は
    // res/values/ids.xml の native_label)。
    private val textView = TextView(context).apply {
        text = "ネイティブのラベル"
        gravity = Gravity.CENTER
        id = R.id.native_label
        contentDescription = "native_label"
    }

    override fun getView(): View = textView

    override fun dispose() {}
}
