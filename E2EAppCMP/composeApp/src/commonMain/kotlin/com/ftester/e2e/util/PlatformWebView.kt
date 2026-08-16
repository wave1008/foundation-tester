package com.ftester.e2e.util

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

// CMP に WebView は無いので、各 OS のネイティブ View を interop で埋め込む
// (Android=AndroidView + android.webkit.WebView / iOS=UIKitView + WKWebView)。
// html はネットワークを使わずに読み込む(フリートの回線状態に依存させない)。
@Composable
expect fun PlatformWebView(html: String, modifier: Modifier)
