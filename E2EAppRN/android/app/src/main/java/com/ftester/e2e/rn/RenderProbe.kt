package com.ftester.e2e.rn

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.view.ViewTreeObserver
import java.io.File
import java.io.FileWriter

/**
 * 計測用の描画プローブ(目印 render-probe.on があるときだけ動く)。目印とログの置き場は2つ:
 * filesDir(debuggable なら `adb shell run-as <pkg> touch files/render-probe.on`)と、release ビルド向けの
 * getExternalFilesDir(null)(`adb shell touch /sdcard/Android/data/<pkg>/files/render-probe.on`)。目印のある方へログを書く。
 * 前面の Activity の View 木が描画されるたび(ViewTreeObserver.OnDrawListener = 無効化されたフレームだけ。Compose の
 * アニメーションも ComposeView の描き直しで届く)に、壁時計の時刻(ms)を render-probe.log へ1行ずつ追記する。
 * 壁時計にするのは Emulator の uptime がホストと別の時計のため(ホスト側が adb の往復で差を測って揃える)。
 * 同じ本体: E2EAppAndroid / E2EAppCMP(androidMain) / E2EAppRN(android)の RenderProbe.kt。iOS 側は E2EAppIOS/Sources/Util/RenderProbe.swift。
 */
object RenderProbe {
    private var writer: FileWriter? = null

    fun startIfRequested(app: Application) {
        val dir = listOfNotNull(app.filesDir, app.getExternalFilesDir(null))
            .firstOrNull { File(it, "render-probe.on").exists() } ?: return
        writer = FileWriter(File(dir, "render-probe.log"), false)
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                val observer = activity.window.decorView.viewTreeObserver
                observer.addOnDrawListener(ViewTreeObserver.OnDrawListener { record() })
            }
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    private fun record() {
        val w = writer ?: return
        w.write("${System.currentTimeMillis()}\n")
        w.flush()
    }
}
