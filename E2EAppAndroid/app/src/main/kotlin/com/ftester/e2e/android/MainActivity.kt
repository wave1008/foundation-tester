package com.ftester.e2e.android

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

enum class Screen { SELECTOR, INPUT, GESTURE, MAP, SCROLL, ASYNC, DIALOG, LIFECYCLE, HEAL, DIAGNOSTICS, NOID, WEBVIEW }

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

        // 起動時リセット(ホームのルート)を先に確定させてからディープリンクを適用する
        // (E2EAppCMP/docs/ui-contract.md §ディープリンク)。
        render()
        handleDeepLink(intent)
    }

    // singleTop: 既に前面にいるプロセスへ届いたときは onCreate を経由せずここが呼ばれる。
    // setIntent() を呼ばないと次回 getIntent() が古い intent を返す(標準の罠)。
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDeepLink(intent)
    }

    private fun handleDeepLink(intent: Intent?) {
        val uri = intent?.data ?: return
        DeepLinkState.lastUrl = uri.toString()
        val screen = routeDeepLink(uri)
        if (screen != null) {
            tab = Tab.HOME
            homeChild = screen
        }
        // 未知の URL は render() だけ行い遷移しない(ライフサイクル画面が開いていれば
        // #txt_last_deeplink の表示を更新するため)。
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
                Screen.GESTURE -> buildGestureScreen(this, container) { navigate(Screen.MAP) }
                Screen.MAP -> buildMapScreen(this, container)
                Screen.SCROLL -> buildScrollScreen(this, container)
                Screen.ASYNC -> buildAsyncScreen(this, container)
                Screen.DIALOG -> buildDialogScreen(this, container)
                Screen.LIFECYCLE -> buildLifecycleScreen(this, container)
                Screen.HEAL -> buildHealScreen(this, container)
                Screen.DIAGNOSTICS -> buildDiagnosticsScreen(this, container)
                Screen.NOID -> buildNoIdScreen(this, container)
                Screen.WEBVIEW -> buildWebviewScreen(this, container)
            }
        }
        container.addView(view)
    }

    // 契約表(E2EAppCMP/docs/ui-contract.md §ディープリンク)の2行だけをルーティングする。
    // クエリは見ない(uri.path はクエリを含まない)。未知の host/path は null = 遷移しない。
    private fun routeDeepLink(uri: Uri): Screen? {
        if (uri.scheme != "fte2eandroid" || uri.host != "screen") return null
        return when (uri.path) {
            "/selector" -> Screen.SELECTOR
            "/lifecycle" -> Screen.LIFECYCLE
            else -> null
        }
    }

    private fun titleFor(): String = when (tab) {
        Tab.CONTROLS -> "コントロール"
        Tab.ABOUT -> "情報"
        Tab.HOME -> when (homeChild) {
            null -> "ホーム"
            Screen.SELECTOR -> "セレクタ"
            Screen.INPUT -> "テキスト入力"
            Screen.GESTURE -> "ジェスチャ"
            Screen.MAP -> "マップ"
            Screen.SCROLL -> "スクロール"
            Screen.ASYNC -> "非同期表示"
            Screen.DIALOG -> "ダイアログ"
            Screen.LIFECYCLE -> "ライフサイクル"
            Screen.HEAL -> "自己修復"
            Screen.DIAGNOSTICS -> "診断"
            Screen.NOID -> "ID なし"
            Screen.WEBVIEW -> "WebView"
        }
    }
}
