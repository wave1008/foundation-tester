package com.ftester.e2e.screens

import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Checkbox
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import kotlin.math.roundToInt

@Composable
fun ControlsScreen() {
    var notify by remember { mutableStateOf(false) }
    var agree by remember { mutableStateOf(false) }
    var plan by remember { mutableStateOf("A") }
    var volume by remember { mutableStateOf(50f) }

    ScreenColumn(scrollable = true) {
        // ラベル Text とコントロール本体を別要素にする: タップ対象はコントロール本体のみ(ラベルは非対象)。
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("通知")
            Switch(
                checked = notify,
                onCheckedChange = { notify = it },
                modifier = Modifier.testTag(Tags.SW_NOTIFY)
            )
        }
        TaggedText(Tags.TXT_SW_NOTIFY, "notify=${if (notify) "on" else "off"}")

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("同意する")
            Checkbox(
                checked = agree,
                onCheckedChange = { agree = it },
                modifier = Modifier.testTag(Tags.CB_AGREE)
            )
        }
        TaggedText(Tags.TXT_CB_AGREE, "agree=$agree")

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("プランA")
            RadioButton(
                selected = plan == "A",
                onClick = { plan = "A" },
                modifier = Modifier.testTag(Tags.RADIO_A)
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("プランB")
            RadioButton(
                selected = plan == "B",
                onClick = { plan = "B" },
                modifier = Modifier.testTag(Tags.RADIO_B)
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("プランC")
            RadioButton(
                selected = plan == "C",
                onClick = { plan = "C" },
                modifier = Modifier.testTag(Tags.RADIO_C)
            )
        }
        TaggedText(Tags.TXT_RADIO, "plan=$plan")

        // steps=3: 0..100 を 25 刻みの 5 段(0/25/50/75/100)にする契約値。
        Slider(
            value = volume,
            onValueChange = { volume = it },
            valueRange = 0f..100f,
            steps = 3,
            modifier = Modifier.testTag(Tags.SLIDER_VOLUME)
        )
        TaggedText(Tags.TXT_SLIDER, "volume=${volume.roundToInt()}")

        TaggedButton(Tags.BTN_CONTROLS_RESET, "コントロールリセット") {
            notify = false
            agree = false
            plan = "A"
            volume = 50f
        }
    }
}
