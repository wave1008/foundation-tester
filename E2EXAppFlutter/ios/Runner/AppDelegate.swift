import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // #native_label の PlatformView 用ファクトリ。Dart 側は lib/screens/native_screen.dart の
    // UiKitView(viewType: "native_label_view")から参照する
    // (E2EXAppCMP/docs/ui-contract-wave2.md §固有部品)。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativeLabelViewPlugin") {
      registrar.register(NativeLabelViewFactory(), withId: "native_label_view")
    }
  }
}

class NativeLabelViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    return NativeLabelView(frame: frame)
  }
}

class NativeLabelView: NSObject, FlutterPlatformView {
  private let label: UILabel

  init(frame: CGRect) {
    label = UILabel(frame: frame)
    label.text = "ネイティブのラベル"
    label.textAlignment = .center
    // シナリオはこの identifier で参照する(#native_label。契約どおり)。
    label.accessibilityIdentifier = "native_label"
    label.isAccessibilityElement = true
    super.init()
  }

  func view() -> UIView {
    return label
  }
}
