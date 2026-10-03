import Observation
import SwiftUI

enum AppTab: Hashable {
    case home, movements, planning, money, search
}

/// App-wide navigation state that App Intents and menu commands can drive.
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var tab: AppTab = .home
    var isAddPresented = false
    var isSettingsPresented = false

    func presentAdd() {
        isAddPresented = true
    }
}

/// User preferences (DESIGN §7, §19).
enum Preferences {
    static let paydayKey = "payday"
    static let sobraModeKey = "sobraMode"

    static var payday: Int {
        let stored = UserDefaults.standard.integer(forKey: paydayKey)
        return stored == 0 ? PayCycle.defaultPayday : stored
    }

    static var currentCycle: PayCycle { PayCycle(containing: .now, payday: payday) }
}

/// How "Sobra do mês" is computed (DESIGN §7).
enum SobraMode: String, CaseIterable {
    /// Σ limits − spent in limits.
    case plan
    /// Salary (or last cycle's, until it lands) + other income − everything spent.
    case income

    var label: String {
        switch self {
        case .plan: "Pelos limites"
        case .income: "Pelo salário"
        }
    }
}
