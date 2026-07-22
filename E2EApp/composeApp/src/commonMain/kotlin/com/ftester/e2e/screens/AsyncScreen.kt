package com.ftester.e2e.screens

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun AsyncScreen() {
    var state by remember { mutableStateOf("idle") }
    var showDelayed by remember { mutableStateOf(false) }
    var countdown by remember { mutableStateOf<Int?>(null) }
    var job by remember { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()

    fun startDelay(seconds: Int, withCountdown: Boolean) {
        // 前回タイマを cancel しないと、古い遅延が後から done を書き込んで検証を壊す。
        job?.cancel()
        state = "waiting"
        showDelayed = false
        countdown = null
        job = scope.launch {
            if (withCountdown) {
                for (n in seconds downTo 1) {
                    countdown = n
                    delay(1000)
                }
                countdown = 0
            } else {
                delay(seconds * 1000L)
            }
            state = "done"
            showDelayed = true
        }
    }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.TXT_DELAY_STATE, "state=$state")
        TaggedButton(Tags.BTN_DELAY_1, "1秒後に表示") { startDelay(1, withCountdown = false) }
        TaggedButton(Tags.BTN_DELAY_3, "3秒後に表示") { startDelay(3, withCountdown = true) }
        TaggedButton(Tags.BTN_DELAY_8, "8秒後に表示") { startDelay(8, withCountdown = false) }
        // showDelayed=false の間はツリーに置かない(非表示ではなく未配置であることが検証点)。
        if (showDelayed) {
            TaggedText(Tags.TXT_DELAYED, "遅延表示 完了")
        }
        countdown?.let { n ->
            TaggedText(Tags.TXT_COUNTDOWN, "count=$n")
        }
        TaggedButton(Tags.BTN_ASYNC_RESET, "非同期リセット") {
            job?.cancel()
            job = null
            state = "idle"
            showDelayed = false
            countdown = null
        }
    }
}
