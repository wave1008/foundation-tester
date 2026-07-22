package com.ftester.e2e.android

import android.app.Activity
import android.view.View
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

// この画面だけ Compose(他は View/XML)。View 中心アプリに ComposeView が混ざったときの
// スナップショット差(型語彙・testTagsAsResourceId の要否)を検証するために意図的に混ぜている。
fun buildControlsScreen(activity: Activity): View = ComposeView(activity).apply {
    setContent { ControlsContent() }
}

@androidx.compose.runtime.Composable
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
private fun ControlsContent() {
    var notify by remember { mutableStateOf(false) }
    var agree by remember { mutableStateOf(false) }
    var plan by remember { mutableStateOf("A") }
    var volume by remember { mutableStateOf(50f) }

    MaterialTheme {
        // testTagsAsResourceId が無いと Compose 部分だけ #id を一切引けない
        // (View 側は resource-id が自動で出るのに ComposeView の中だけ落ちる)。
        Column(
            modifier = Modifier
                .fillMaxSize()
                .semantics { testTagsAsResourceId = true }
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            // ラベル Text とコントロール本体を別要素にする(タップ対象は本体のみ)。
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("通知")
                Switch(checked = notify, onCheckedChange = { notify = it },
                    modifier = Modifier.testTag("sw_notify"))
            }
            Text("notify=${if (notify) "on" else "off"}", modifier = Modifier.testTag("txt_sw_notify"))

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("同意する")
                Checkbox(checked = agree, onCheckedChange = { agree = it },
                    modifier = Modifier.testTag("cb_agree"))
            }
            Text("agree=$agree", modifier = Modifier.testTag("txt_cb_agree"))

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("プランA")
                RadioButton(selected = plan == "A", onClick = { plan = "A" },
                    modifier = Modifier.testTag("radio_a"))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("プランB")
                RadioButton(selected = plan == "B", onClick = { plan = "B" },
                    modifier = Modifier.testTag("radio_b"))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("プランC")
                RadioButton(selected = plan == "C", onClick = { plan = "C" },
                    modifier = Modifier.testTag("radio_c"))
            }
            Text("plan=$plan", modifier = Modifier.testTag("txt_radio"))

            // steps=3: 0..100 を 25 刻みの 5 段(0/25/50/75/100)にする契約値。
            Slider(value = volume, onValueChange = { volume = it },
                valueRange = 0f..100f, steps = 3,
                modifier = Modifier.testTag("slider_volume"))
            Text("volume=${volume.roundToInt()}", modifier = Modifier.testTag("txt_slider"))

            Button(onClick = {
                notify = false
                agree = false
                plan = "A"
                volume = 50f
            }, modifier = Modifier.testTag("btn_controls_reset")) {
                Text("コントロールリセット")
            }
        }
    }
}
