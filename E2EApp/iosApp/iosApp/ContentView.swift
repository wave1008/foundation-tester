import UIKit
import SwiftUI
import ComposeApp

// MainViewController は composeApp/iosMain の MainViewController.kt(トップレベル関数)。
// Kotlin/Native が MainViewControllerKt にラップする。
struct ComposeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        ComposeView()
            .ignoresSafeArea(.keyboard) // Compose 側で IME を処理
    }
}
