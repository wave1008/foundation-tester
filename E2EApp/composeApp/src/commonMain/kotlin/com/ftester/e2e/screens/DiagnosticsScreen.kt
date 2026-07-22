package com.ftester.e2e.screens

import androidx.compose.material3.AlertDialog
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.ftester.e2e.AppInfo
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import com.ftester.e2e.util.exposeTestTagsAsResourceId
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource

@Composable
fun DiagnosticsScreen() {
    var confirmOpen by remember { mutableStateOf(false) }
    var crashNow by remember { mutableStateOf(false) }

    // composition 外(メインスレッド)で例外送出: クラッシュレポート添付・ブリッジ切断の検証材料。
    LaunchedEffect(crashNow) {
        if (crashNow) throw RuntimeException("FT_E2E intentional crash")
    }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.TXT_BUILD_INFO, "build=${AppInfo.VERSION}")
        TaggedText(Tags.TXT_DIAG_NOTE, "診断メニュー")
        TaggedButton(Tags.BTN_FREEZE_3S, "3秒フリーズ") {
            // ブリッジのタイムアウト挙動検証用にメインスレッドを 3 秒ブロックする。
            // runBlocking は commonMain に無い(concurrent ソースセット限定)ためビジーループで代替する。
            val start = TimeSource.Monotonic.markNow()
            @Suppress("ControlFlowWithEmptyBody")
            while (start.elapsedNow() < 3.seconds) {
            }
        }
        TaggedButton(Tags.BTN_CRASH, "クラッシュさせる") {
            confirmOpen = true
        }
    }

    if (confirmOpen) {
        // 別ウィンドウ描画のため App() ルートの exposeTestTagsAsResourceId() が届かない。再適用必須。
        AlertDialog(
            modifier = Modifier.exposeTestTagsAsResourceId(),
            onDismissRequest = { confirmOpen = false },
            confirmButton = {
                TaggedButton(Tags.BTN_CRASH_CONFIRM, "本当にクラッシュ") {
                    confirmOpen = false
                    crashNow = true
                }
            },
            dismissButton = {
                TaggedButton(Tags.BTN_CRASH_CANCEL, "やめる") {
                    confirmOpen = false
                }
            }
        )
    }
}
