import SwiftUI

/// NavigationLink(value:) はスタック内のどの深さからでも、祖先の NavigationStack が
/// 持つ path に自動で追記される。RootView は path を自前で持たない(プッシュ専用の
/// 遷移しか無いため。プロセス起動ごとに NavigationStack が積み直され、常にホームへ戻る)。
enum Route: Hashable {
    case pager, sheet, menu, date, refresh, snackbar, grid, swipe, tabs, anim, chips, search
    case detailMenu, detail(Int)
    case collapse, sticky, time, dialogs, context, reorder, inputs, fab, expand, stepper, infinite, zoom, native
}

@main
struct FTE2EXIOSApp: App {
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
        case .pager: PagerScreen()
        case .sheet: SheetScreen()
        case .menu: MenuScreen()
        case .date: DateScreen()
        case .refresh: RefreshScreen()
        case .snackbar: SnackbarScreen()
        case .grid: GridScreen()
        case .swipe: SwipeScreen()
        case .tabs: TabsScreen()
        case .anim: AnimScreen()
        case .chips: ChipsScreen()
        case .search: SearchScreen()
        case .detailMenu: DetailMenuScreen()
        case .detail(let id): DetailScreen(id: id)
        case .collapse: CollapseScreen()
        case .sticky: StickyScreen()
        case .time: TimeScreen()
        case .dialogs: DialogsScreen()
        case .context: ContextScreen()
        case .reorder: ReorderScreen()
        case .inputs: InputsScreen()
        case .fab: FabScreen()
        case .expand: ExpandScreen()
        case .stepper: StepperScreen()
        case .infinite: InfiniteScreen()
        case .zoom: ZoomScreen()
        case .native: NativeScreen()
        }
    }
}
