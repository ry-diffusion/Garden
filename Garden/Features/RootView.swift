import SwiftData
import SwiftUI

/// Five peers (DESIGN §15): tab bar on iPhone, sidebar on iPad and Mac.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Início", systemImage: "leaf", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            Tab("Extrato", systemImage: "list.bullet.rectangle", value: AppTab.movements) {
                NavigationStack { MovementsView() }
            }
            Tab("Categorias", systemImage: "chart.pie", value: AppTab.planning) {
                NavigationStack { CategoriesView() }
            }
            Tab("Patrimônio", systemImage: "banknote", value: AppTab.money) {
                NavigationStack { MoneyView() }
            }
            Tab("Buscar", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .task { await Ledger(context: context).enrichPendingMerchants() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Task { await SyncEngine.shared.syncIfStale() } }
        }
        .sheet(isPresented: $router.isAddPresented) {
            AddMovementSheet()
        }
        #if !os(macOS)
        .sheet(isPresented: $router.isSettingsPresented) {
            NavigationStack { SettingsView() }
        }
        #endif
    }
}

/// Toolbar shared by tab roots: Lançar (+) and, on iPhone/iPad, Ajustes.
struct RootToolbar: ToolbarContent {
    @Environment(AppRouter.self) private var router

    var body: some ToolbarContent {
        #if !os(macOS)
        ToolbarItem(placement: .topBarLeading) {
            Button("Ajustes", systemImage: "gearshape") { router.isSettingsPresented = true }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Button("Lançar", systemImage: "plus") { router.presentAdd() }
        }
    }
}
