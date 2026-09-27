package com.ftester.e2ex.screens

import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.RangeSlider
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedText
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChipsScreen() {
    var wifiSelected by remember { mutableStateOf(false) }
    var assistResult by remember { mutableStateOf("none") }
    var seg by remember { mutableStateOf("day") }
    var range by remember { mutableStateOf(20f..80f) }

    ScreenColumn(scrollable = true) {
        FilterChip(
            selected = wifiSelected,
            onClick = { wifiSelected = !wifiSelected },
            label = { Text("Wi-Fi") },
            modifier = Modifier.testTag(Tags.CHIP_WIFI)
        )
        TaggedText(Tags.CHIP_RESULT, "wifi=$wifiSelected")

        AssistChip(
            onClick = { assistResult = "tapped" },
            label = { Text("ヘルプ") },
            modifier = Modifier.testTag(Tags.CHIP_ASSIST)
        )
        TaggedText(Tags.ASSIST_RESULT, "assist=$assistResult")

        SingleChoiceSegmentedButtonRow {
            SegmentedButton(
                selected = seg == "day",
                onClick = { seg = "day" },
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 3),
                modifier = Modifier.testTag(Tags.SEG_DAY)
            ) { Text("日") }
            SegmentedButton(
                selected = seg == "week",
                onClick = { seg = "week" },
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 3),
                modifier = Modifier.testTag(Tags.SEG_WEEK)
            ) { Text("週") }
            SegmentedButton(
                selected = seg == "month",
                onClick = { seg = "month" },
                shape = SegmentedButtonDefaults.itemShape(index = 2, count = 3),
                modifier = Modifier.testTag(Tags.SEG_MONTH)
            ) { Text("月") }
        }
        TaggedText(Tags.SEG_RESULT, "seg=$seg")

        RangeSlider(
            value = range,
            onValueChange = { range = it },
            valueRange = 0f..100f,
            modifier = Modifier.testTag(Tags.RANGE_SLIDER)
        )
        TaggedText(Tags.RANGE_RESULT, "range=${range.start.roundToInt()}-${range.endInclusive.roundToInt()}")
    }
}
