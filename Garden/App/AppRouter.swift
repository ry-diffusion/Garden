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
    /// Global spending cap per cycle, in centavos (0 = none).
    static let monthlyCapKey = "monthlyCapCents"

    static var monthlyCap: Money? {
        let cents = UserDefaults.standard.integer(forKey: monthlyCapKey)
        return cents > 0 ? Money(cents: Int64(cents)) : nil
    }

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
    /// One global cap ("no máximo R$ 5.000 no mês") − everything spent.
    case cap

    var label: String {
        switch self {
        case .plan: "Pelos limites das categorias"
        case .income: "Pelo salário"
        case .cap: "Pelo teto do mês"
        }
    }

    var explanation: String {
        switch self {
        case .plan: "A Sobra do mês é a soma dos limites das categorias menos o que já foi gasto nelas."
        case .income: "A Sobra do mês é o salário do ciclo (ou o do ciclo anterior, até o novo cair) mais outras entradas, menos tudo o que você gastou."
        case .cap: "A Sobra do mês é o teto menos tudo o que você gastou no ciclo, em qualquer categoria."
        }
    }
}
