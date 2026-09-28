package com.ftester.e2ex

import androidx.compose.ui.uikit.OnFocusBehavior
import androidx.compose.ui.window.ComposeUIViewController
import platform.UIKit.UIViewController

// 既定の FocusableAboveKeyboard はキーボードの高さぶん画面全体を押し上げ、上部に固定した echo を画面外へ出す。
// DoNothing にしてキーボードの避け方は各画面の imePadding に任せる(入力の種類の画面の契約)
fun MainViewController(): UIViewController = ComposeUIViewController(
    configure = { onFocusBehavior = OnFocusBehavior.DoNothing }
) { App() }
