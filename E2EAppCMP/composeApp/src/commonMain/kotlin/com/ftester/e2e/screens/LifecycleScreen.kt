package com.ftester.e2e.screens

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import com.ftester.e2e.util.LaunchCounter
import com.ftester.e2e.util.platformName

// remember ではなく object: relaunch 検証は「画面離脱後も session が保持され、relaunch でのみ 0 に戻る」ことが要件。
private object SessionCounter {
    var value by mutableStateOf(0)
}

@Composable
fun LifecycleScreen() {
    ScreenColumn(scrollable = true) {
        TaggedText(Tags.TXT_LAUNCH_COUNT, "launch=${LaunchCounter.value}")
        TaggedText(Tags.TXT_SESSION_COUNT, "session=${SessionCounter.value}")
        TaggedButton(Tags.BTN_SESSION_INC, "セッション+1") {
            SessionCounter.value++
        }
        TaggedButton(Tags.BTN_RESET_PERSISTED, "永続カウンタをリセット") {
            LaunchCounter.reset()
        }
        TaggedText(Tags.TXT_PLATFORM, "platform=${platformName()}")
    }
}
