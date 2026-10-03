import SwiftData
import SwiftUI

@main struct MyApp: App {
    @State private var router = AppRouter.shared

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-seedDemo") {
            DemoData.seedIfEmpty(GardenStore.shared.mainContext)
        }
        DemoData.pairFromLaunchArguments()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(\.locale, Money.brazil)
                .fontDesign(.rounded)
        }
        .modelContainer(GardenStore.shared)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Lançar") { router.presentAdd() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Ir") {
                Button("Início") { router.tab = .home }.keyboardShortcut("1")
                Button("Extrato") { router.tab = .movements }.keyboardShortcut("2")
                Button("Categorias") { router.tab = .planning }.keyboardShortcut("3")
                Button("Patrimônio") { router.tab = .money }.keyboardShortcut("4")
                Button("Buscar") { router.tab = .search }.keyboardShortcut("f")
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .modelContainer(GardenStore.shared)
        }
        #endif
    }
}
