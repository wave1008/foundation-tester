package com.ftester.e2e.util

import android.annotation.SuppressLint
import android.webkit.WebView
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

@SuppressLint("SetJavaScriptEnabled")
@Composable
actual fun PlatformWebView(html: String, modifier: Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                // baseURL=null の loadDataWithBaseURL(loadData だと日本語が化ける)
                loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
            }
        }
    )
}
