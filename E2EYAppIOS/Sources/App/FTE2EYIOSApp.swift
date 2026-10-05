import SwiftUI

/// NavigationLink(value:) で積む。A8 の編集画面だけは A8 が自前の状態を持つので route を使わない(BackGuardScreen)。
enum Route: Hashable {
    case nested, chat, loading, swipeActions, select, links, pin, backGuard, player, hideBars, tabHeader, staggered
}

@main
struct FTE2EYIOSApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            HomeScreen()
                .navigationDestination(for: Route.self) { destination(for: $0) }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .nested: NestedScreen()
        case .chat: ChatScreen()
        case .loading: LoadingScreen()
        case .swipeActions: SwipeActionsScreen()
        case .select: SelectScreen()
        case .links: LinksScreen()
        case .pin: PinScreen()
        case .backGuard: BackGuardScreen()
        case .player: PlayerScreen()
        case .hideBars: HideBarsScreen()
        case .tabHeader: TabHeaderScreen()
        case .staggered: StaggeredScreen()
        }
    }
}
