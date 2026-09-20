package com.ftester.e2e.rn

import android.app.Application
import android.webkit.WebView
import com.facebook.react.PackageList
import com.facebook.react.ReactApplication
import com.facebook.react.ReactHost
import com.facebook.react.ReactNativeApplicationEntryPoint.loadReactNative
import com.facebook.react.defaults.DefaultReactHost.getDefaultReactHost

class MainApplication : Application(), ReactApplication {

  override val reactHost: ReactHost by lazy {
    getDefaultReactHost(
      context = applicationContext,
      packageList =
        PackageList(this).packages.apply {
          // Packages that cannot be autolinked yet can be added manually here, for example:
          // add(MyReactNativePackage())
        },
    )
  }

  override fun onCreate() {
    super.onCreate()
    // この SUT だけ release ビルド(debug APK は Metro を要求する)なので DEBUGGABLE フラグが無い。
    // これを呼ばないと WebView の devtools ソケットが開かず、ro.debuggable=0 の実機では
    // fleetest が DOM を読めない(他の SUT は debuggable ビルドなので既定で開く)
    WebView.setWebContentsDebuggingEnabled(true)
    loadReactNative(this)
  }
}
