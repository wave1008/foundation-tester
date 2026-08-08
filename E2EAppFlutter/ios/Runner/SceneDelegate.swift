import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                       options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      FTDeepLink.attach(to: controller)
    }
    if let url = connectionOptions.urlContexts.first?.url {
      FTDeepLink.handleColdStart(url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    if let url = URLContexts.first?.url {
      FTDeepLink.handleRuntime(url)
    }
  }
}

/// fte2eflutter:// を Dart へ渡す唯一の経路(MethodChannel。採用理由は
/// E2EAppFlutter/docs/ui-contract.md)。getInitialUrl は cold start の URL を
/// Dart 側からの pull で一度だけ返す(配送タイミングが engine 起動と競合するため push しない)。
/// onNewUrl は起動済みプロセスへの push。
enum FTDeepLink {
  private static let channelName = "com.ftester.e2e.flutter/deeplink"
  private static var channel: FlutterMethodChannel?
  private static var pendingInitialURL: URL?

  static func attach(to controller: FlutterViewController) {
    let ch = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
    ch.setMethodCallHandler { call, result in
      guard call.method == "getInitialUrl" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(pendingInitialURL?.absoluteString)
      pendingInitialURL = nil
    }
    channel = ch
  }

  static func handleColdStart(_ url: URL) {
    pendingInitialURL = url
  }

  static func handleRuntime(_ url: URL) {
    channel?.invokeMethod("onNewUrl", arguments: url.absoluteString)
  }
}
