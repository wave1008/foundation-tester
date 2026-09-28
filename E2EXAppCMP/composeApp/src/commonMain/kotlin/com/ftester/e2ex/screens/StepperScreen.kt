package com.ftester.e2ex.screens

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText
import kotlinx.coroutines.launch

@Composable
fun StepperScreen() {
    var qty by remember { mutableStateOf(Tags.QTY_INITIAL) }
    var progressState by remember { mutableStateOf("idle") }
    val progress = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()

    ScreenColumn(scrollable = true) {
        Row(modifier = Modifier.fillMaxWidth().testTag(Tags.STEPPER_QTY)) {
            TaggedButton(Tags.BTN_QTY_MINUS, "-") { if (qty > Tags.QTY_MIN) qty-- }
            TaggedButton(Tags.BTN_QTY_PLUS, "+") { if (qty < Tags.QTY_MAX) qty++ }
        }
        TaggedText(Tags.QTY_RESULT, "qty=$qty")

        TaggedButton(Tags.BTN_START_PROGRESS, "進捗を開始") {
            scope.launch {
                progressState = "running"
                progress.snapTo(0f)
                progress.animateTo(1f, tween(Tags.PROGRESS_DURATION_MS))
                progressState = "done"
            }
        }
        LinearProgressIndicator(
            progress = { progress.value },
            modifier = Modifier.fillMaxWidth().testTag(Tags.PROGRESS_MAIN)
        )
        TaggedText(Tags.PROGRESS_RESULT, "progress=$progressState")
        if (progressState == "running") {
            CircularProgressIndicator(modifier = Modifier.testTag(Tags.SPINNER_BUSY))
        }
    }
}
