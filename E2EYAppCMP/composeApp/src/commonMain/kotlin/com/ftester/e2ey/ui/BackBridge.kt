package com.ftester.e2ey.ui

// A8: 画面側の BackHandler と同じ処理を、シェルの #btn_back からも呼ぶための橋。
// 登録は EditorScreen の DisposableEffect だけ(離脱で必ず null に戻す)。
object BackBridge {
    var handler: (() -> Unit)? = null
}
