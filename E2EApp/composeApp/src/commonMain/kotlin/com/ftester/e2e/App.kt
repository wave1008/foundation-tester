package com.ftester.e2e

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ftester.e2e.screens.AboutScreen
import com.ftester.e2e.screens.AsyncScreen
import com.ftester.e2e.screens.ControlsScreen
import com.ftester.e2e.screens.DialogScreen
import com.ftester.e2e.screens.DiagnosticsScreen
import com.ftester.e2e.screens.GestureScreen
import com.ftester.e2e.screens.HealScreen
import com.ftester.e2e.screens.HomeScreen
import com.ftester.e2e.screens.InputScreen
import com.ftester.e2e.screens.LifecycleScreen
import com.ftester.e2e.screens.ScrollScreen
import com.ftester.e2e.screens.SelectorScreen
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import com.ftester.e2e.util.LaunchCounter
import com.ftester.e2e.util.exposeTestTagsAsResourceId

enum class Screen {
    HOME, SELECTOR, INPUT, GESTURE, SCROLL, ASYNC, DIALOG, LIFECYCLE, HEAL, DIAGNOSTICS, CONTROLS, ABOUT
}

private enum class Tab { HOME, CONTROLS, ABOUT }

private fun titleFor(tab: Tab, homeChild: Screen?): String = when (tab) {
    Tab.CONTROLS -> "コントロール"
    Tab.ABOUT -> "情報"
    Tab.HOME -> when (homeChild) {
        null -> "ホーム"
        Screen.SELECTOR -> "セレクタ"
        Screen.INPUT -> "テキスト入力"
        Screen.GESTURE -> "ジェスチャ"
        Screen.SCROLL -> "スクロール"
        Screen.ASYNC -> "非同期表示"
        Screen.DIALOG -> "ダイアログ"
        Screen.LIFECYCLE -> "ライフサイクル"
        Screen.HEAL -> "自己修復"
        Screen.DIAGNOSTICS -> "診断"
        else -> "ホーム"
    }
}

@Composable
fun App() {
    LaunchCounter.ensureCounted()

    var tab by remember { mutableStateOf(Tab.HOME) }
    var homeChild by remember { mutableStateOf<Screen?>(null) }

    fun switchTab(next: Tab) {
        tab = next
        homeChild = null
    }

    MaterialTheme {
        // exposeTestTagsAsResourceId が無いと Android で #id が一切引けない(testTagsAsResourceId は
        // ルートで1回設定すれば子孫全体に効く)。
        // safeDrawing: Android は enableEdgeToEdge()、iOS は ignoresSafeArea で描画するため、
        // これが無いと下部タブがシステムナビ/ホームインジケータの下に潜って tap が届かない。
        Column(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .exposeTestTagsAsResourceId()
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (homeChild != null) {
                    TaggedButton(Tags.BACK, "戻る", onClick = { homeChild = null })
                }
                TaggedText(Tags.SCREEN_TITLE, titleFor(tab, homeChild), modifier = Modifier.weight(1f))
            }

            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                when (tab) {
                    Tab.CONTROLS -> ControlsScreen()
                    Tab.ABOUT -> AboutScreen()
                    Tab.HOME -> when (homeChild) {
                        null -> HomeScreen(onNavigate = { screen -> homeChild = screen })
                        Screen.SELECTOR -> SelectorScreen()
                        Screen.INPUT -> InputScreen()
                        Screen.GESTURE -> GestureScreen()
                        Screen.SCROLL -> ScrollScreen()
                        Screen.ASYNC -> AsyncScreen()
                        Screen.DIALOG -> DialogScreen()
                        Screen.LIFECYCLE -> LifecycleScreen()
                        Screen.HEAL -> HealScreen()
                        Screen.DIAGNOSTICS -> DiagnosticsScreen()
                        else -> HomeScreen(onNavigate = { screen -> homeChild = screen })
                    }
                }
            }

            Row(modifier = Modifier.fillMaxWidth()) {
                TaggedButton(Tags.TAB_HOME, "ホーム", modifier = Modifier.weight(1f), onClick = { switchTab(Tab.HOME) })
                TaggedButton(Tags.TAB_CONTROLS, "コントロール", modifier = Modifier.weight(1f), onClick = { switchTab(Tab.CONTROLS) })
                TaggedButton(Tags.TAB_ABOUT, "情報", modifier = Modifier.weight(1f), onClick = { switchTab(Tab.ABOUT) })
            }
        }
    }
}
