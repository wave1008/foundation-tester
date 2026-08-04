package com.ftester.e2e.util

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.UIKitInteropProperties
import androidx.compose.ui.viewinterop.UIKitView
import kotlinx.cinterop.readValue
import platform.CoreGraphics.CGRectZero
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration

@OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
@Composable
actual fun PlatformWebView(html: String, modifier: Modifier) {
    UIKitView(
        modifier = modifier,
        // **必須**: 既定(false)だと Compose 側の a11y ツリーが interop ビューを1ノードに畳み、
        // WKWebView の中身が XCUITest から一切見えない(2026-07-29 実測。15秒待っても出ない)
        properties = UIKitInteropProperties(isNativeAccessibilityEnabled = true),
        factory = {
            WKWebView(frame = CGRectZero.readValue(), configuration = WKWebViewConfiguration()).apply {
                loadHTMLString(html, baseURL = null)
            }
        }
    )
}
