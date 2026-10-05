package com.ftester.e2ey.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.ftester.e2ey.ui.TaggedText
import kotlinx.coroutines.delay

// A7: 6 つの箱 + 隠れた BasicTextField(OTP)/ 自前キーパッド(PIN)。
@Composable
fun PinScreen() {
    var otpResult by remember { mutableStateOf("none") }
    var pinResult by remember { mutableStateOf("none") }
    var otp by remember { mutableStateOf("") }
    var pin by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current

    LaunchedEffect(otp) {
        if (otp.length == 6) {
            delay(300)
            otpResult = otp
            otp = ""
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp, 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            TaggedText("txt_otp_result", "otp=$otpResult")
            TaggedText("txt_pin_result", "pin=$pinResult")
            TaggedText("txt_pin_len", "pin_len=${pin.length}")
        }
        Column(
            modifier = Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Box {
                // 実体の入力欄(箱の裏)。箱を押すとここへ焦点が移る
                BasicTextField(
                    value = otp,
                    onValueChange = { v -> otp = v.filter { it.isDigit() }.take(6) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    modifier = Modifier.size(40.dp).alpha(0f).focusRequester(focus).testTag("field_otp")
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (i in 1..6) {
                        Box(
                            modifier = Modifier.size(44.dp)
                                .border(1.dp, MaterialTheme.colorScheme.outline)
                                .testTag("otp_box_$i")
                                .clickable { focus.requestFocus(); keyboard?.show() },
                            contentAlignment = Alignment.Center
                        ) { Text(otp.getOrNull(i - 1)?.toString() ?: "") }
                    }
                }
            }
            TaggedText("pin_dots", "●".repeat(pin.length))
            val keys = listOf(listOf(1, 2, 3), listOf(4, 5, 6), listOf(7, 8, 9))
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                fun press(d: Int) {
                    val next = pin + d
                    if (next.length == 4) { pinResult = next; pin = "" } else pin = next
                }
                for (r in keys) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (d in r) Button(onClick = { press(d) }, modifier = Modifier.width(72.dp).height(48.dp).testTag("key_$d")) { Text("$d") }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.width(72.dp))
                    Button(onClick = { press(0) }, modifier = Modifier.width(72.dp).height(48.dp).testTag("key_0")) { Text("0") }
                    IconButton(
                        onClick = { pin = pin.dropLast(1) },
                        modifier = Modifier.width(72.dp).height(48.dp).testTag("key_del")
                    ) { Text("⌫", modifier = Modifier.clearAndSetSemantics { contentDescription = "削除" }) }
                }
            }
        }
    }
}
