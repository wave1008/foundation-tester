package com.ftester.e2e.screens

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.ftester.e2e.Screen
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText

@Composable
fun HomeScreen(onNavigate: (Screen) -> Unit) {
    ScreenColumn(scrollable = true) {
        TaggedText(Tags.HOME_MARKER, "E2E ホーム")
        TaggedButton(Tags.NAV_SELECTOR, "セレクタ", modifier = Modifier.fillMaxWidth()) { onNavigate(Screen.SELECTOR) }
        TaggedButton(Tags.NAV_INPUT, "テキスト入力", modifier = Modifier.fillMaxWidth()) { onNavigate(Screen.INPUT) }
        TaggedButton(Tags.NAV_GESTURE, "ジェスチャ", modifier = Modifier.fillMaxWidth()) { onNavigate(Screen.GESTURE) }
        TaggedButton(Tags.NAV_SCROLL, "スクロール", modifier = Modifier.fillMaxWidth()) { onNavigate(Screen.SCROLL) }
        TaggedButton(Tags.NAV_ASYNC, "非同期表示", modifier = Modifier.fillMaxWidth()) { onNavigate(Screen.ASYNC) }
        TaggedButton(Tags.NAV_DIALOG, "ダイアログ", modifier = Modifier.fillMaxWidth()) { onNavigate(Screen.DIALOG) }
        TaggedButton(Tags.NAV_LIFECYCLE, "ライフサイクル", modifier = Modifier.fillMaxWidth()) { onNavigate(Screen.LIFECYCLE) }
        TaggedButton(Tags.NAV_HEAL, "自己修復", modifier = Modifier.fillMaxWidth()) { onNavigate(Screen.HEAL) }
        TaggedButton(Tags.NAV_DIAGNOSTICS, "診断", modifier = Modifier.fillMaxWidth()) { onNavigate(Screen.DIAGNOSTICS) }
    }
}
