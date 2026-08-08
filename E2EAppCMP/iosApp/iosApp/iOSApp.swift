import SwiftUI
import ComposeApp

@main
struct iOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                // onOpenURL は launch 時(URL 起動)・起動済みへの着信の両方で呼ばれる
                // (契約 E2EAppCMP/docs/ui-contract.md §ディープリンク)。
                // DeepLinkRouter は commonMain の Kotlin object。ObjC interop で `.shared` の
                // シングルトンとして露出する(isStatic framework・export 一覧なしで公開 API 全体が出る)。
                .onOpenURL { url in
                    DeepLinkRouter.shared.handle(url: url.absoluteString)
                }
        }
    }
}
