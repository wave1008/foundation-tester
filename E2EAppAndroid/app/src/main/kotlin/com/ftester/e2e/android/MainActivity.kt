package com.ftester.e2e.android

import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

enum class Screen { SELECTOR, INPUT, GESTURE, SCROLL, ASYNC, DIALOG, LIFECYCLE, HEAL, DIAGNOSTICS }

private enum class Tab { HOME, CONTROLS, ABOUT }

class MainActivity : AppCompatActivity() {

    private var tab = Tab.HOME
    private var homeChild: Screen? = null

    private lateinit var container: FrameLayout
    private lateinit var title: TextView
    private lateinit var back: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        // savedInstanceState を捨てる: 「プロセス起動時は必ずホームタブのルート」契約を守るため。
        // super に渡すと Android が View 階層の状態(EditText の文字列など)まで復元してしまい、
        // relaunchApp 後の初期状態が前回実行に汚染される。
        super.onCreate(null)
        setContentView(R.layout.activity_main)

        container = findViewById(R.id.container)
        title = findViewById(R.id.txt_screen_title)
        back = findViewById(R.id.btn_back)

        back.setOnClickListener {
            homeChild = null
            render()
        }
        findViewById<Button>(R.id.tab_home).setOnClickListener { switchTab(Tab.HOME) }
        findViewById<Button>(R.id.tab_controls).setOnClickListener { switchTab(Tab.CONTROLS) }
        findViewById<Button>(R.id.tab_about).setOnClickListener { switchTab(Tab.ABOUT) }

        render()
    }

    /// タブ切替は下位画面スタックを捨てて各タブのルートへ着地する(契約 §シェル)。
    private fun switchTab(next: Tab) {
        tab = next
        homeChild = null
        render()
    }

    private fun navigate(screen: Screen) {
        homeChild = screen
        render()
    }

    private fun render() {
        title.text = titleFor()
        back.visibility = if (tab == Tab.HOME && homeChild != null) View.VISIBLE else View.GONE

        container.removeAllViews()
        val view = when (tab) {
            Tab.CONTROLS -> buildControlsScreen(this)
            Tab.ABOUT -> layoutInflater.inflate(R.layout.screen_about, container, false)
            Tab.HOME -> when (homeChild) {
                null -> buildHomeScreen(this, container, ::navigate)
                Screen.SELECTOR -> buildSelectorScreen(this, container)
                Screen.INPUT -> buildInputScreen(this, container)
                Screen.GESTURE -> buildGestureScreen(this, container)
                Screen.SCROLL -> buildScrollScreen(this, container)
                Screen.ASYNC -> buildAsyncScreen(this, container)
                Screen.DIALOG -> buildDialogScreen(this, container)
                Screen.LIFECYCLE -> buildLifecycleScreen(this, container)
                Screen.HEAL -> buildHealScreen(this, container)
                Screen.DIAGNOSTICS -> buildDiagnosticsScreen(this, container)
            }
        }
        container.addView(view)
    }

    private fun titleFor(): String = when (tab) {
        Tab.CONTROLS -> "コントロール"
        Tab.ABOUT -> "情報"
        Tab.HOME -> when (homeChild) {
            null -> "ホーム"
            Screen.SELECTOR -> "セレクタ"
            Screen.INPUT -> "テキスト入力"
            Screen.GESTURE -> "ジェスチャ"
            Screen.SCROLL -> "スクロール"
            Screen.ASYNC -> "非同期表示"
            Screen.DIALOG -> "ダイアログ"
            Screen.LIFECYCLE -> "ライフサイクル"
            Screen.HEAL -> "自己修復"
            Screen.DIAGNOSTICS -> "診断"
        }
    }
}
