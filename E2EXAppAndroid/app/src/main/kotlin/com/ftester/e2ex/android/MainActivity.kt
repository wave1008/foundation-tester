package com.ftester.e2ex.android

import android.os.Bundle
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.navigation.fragment.NavHostFragment
import com.google.android.material.appbar.MaterialToolbar

class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val toolbar = findViewById<MaterialToolbar>(R.id.toolbar)
        val title = findViewById<TextView>(R.id.txt_screen_title)
        val navHost = supportFragmentManager.findFragmentById(R.id.nav_host_fragment) as NavHostFragment
        val navController = navHost.navController

        // Toolbar の navigationIcon は内部の無名 ImageButton に付く(id は持てない。契約の逸脱として
        // docs/ui-contract.md に記録済み)。押下判定と表示可否だけをここで結線する。
        toolbar.navigationContentDescription = "戻る"
        // navigateUp は親の行き先へ上がるので、詳細を積み重ねた画面で1つずつ戻れない。戻るキーと同じ操作にする
        toolbar.setNavigationOnClickListener { onBackPressedDispatcher.onBackPressed() }

        navController.addOnDestinationChangedListener { _, destination, _ ->
            title.text = destination.label ?: ""
            toolbar.navigationIcon = if (destination.id == R.id.homeFragment) {
                null
            } else {
                ContextCompat.getDrawable(this, R.drawable.ic_back)
            }
        }
    }
}
