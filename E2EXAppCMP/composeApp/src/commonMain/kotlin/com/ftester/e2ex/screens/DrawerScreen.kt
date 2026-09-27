package com.ftester.e2ex.screens

import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.material3.rememberDrawerState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText
import kotlinx.coroutines.launch

@Composable
fun DrawerScreen() {
    val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf("none") }

    fun selectAndClose(value: String) {
        result = value
        scope.launch { drawerState.close() }
    }

    // ModalNavigationDrawer はダイアログ/ポップアップと違い同一ウィンドウに描画されるため、
    // ここでは exposeTestTagsAsResourceId の再適用は不要(契約 §全体規約の列挙に無い)。
    ModalNavigationDrawer(
        drawerState = drawerState,
        gesturesEnabled = true,
        drawerContent = {
            ModalDrawerSheet {
                TaggedText(Tags.DRAWER_HEADER, "ドロワー見出し")
                NavigationDrawerItem(
                    label = { Text("受信箱") },
                    selected = false,
                    onClick = { selectAndClose("inbox") },
                    modifier = Modifier.testTag(Tags.DRAWER_ITEM_INBOX)
                )
                NavigationDrawerItem(
                    label = { Text("送信済み") },
                    selected = false,
                    onClick = { selectAndClose("sent") },
                    modifier = Modifier.testTag(Tags.DRAWER_ITEM_SENT)
                )
                NavigationDrawerItem(
                    label = { Text("ゴミ箱") },
                    selected = false,
                    onClick = { selectAndClose("trash") },
                    modifier = Modifier.testTag(Tags.DRAWER_ITEM_TRASH)
                )
            }
        }
    ) {
        ScreenColumn(scrollable = true) {
            TaggedButton(Tags.BTN_OPEN_DRAWER, "ドロワーを開く") { scope.launch { drawerState.open() } }
            TaggedText(Tags.DRAWER_RESULT, "drawer=$result")
            TaggedText(Tags.DRAWER_STATE, "drawerOpen=${drawerState.isOpen}")
        }
    }
}
