package com.ftester.e2e.rn

import android.content.Intent
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled
import com.facebook.react.defaults.DefaultReactActivityDelegate

class MainActivity : ReactActivity() {

  /**
   * Returns the name of the main component registered from JavaScript. This is used to schedule
   * rendering of the component.
   */
  override fun getMainComponentName(): String = "FTE2ERN"

  /**
   * Returns the instance of the [ReactActivityDelegate]. We use [DefaultReactActivityDelegate]
   * which allows you to enable New Architecture with a single boolean flags [fabricEnabled]
   */
  override fun createReactActivityDelegate(): ReactActivityDelegate =
      DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled)

  // warm 経由のディープリンク(openURL)。singleTop なので既存インスタンスへここが呼ばれる。
  // super.onNewIntent() が ReactActivity → ReactHost.onNewIntent() まで配送し、New Architecture では
  // そちらが JS の Linking 'url' イベントを自動発行する(IntentModule 自体はイベントを出さない。
  // 実測: node_modules/react-native の ReactHostImpl.onNewIntent → emitNewIntentReceived)。
  // setIntent() は Linking.getInitialURL() が読む getIntent() を最新化するために必要。
  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
  }
}
