import Foundation
import SwiftData

/// "Sobra do mês" in the chosen mode (DESIGN §7): cap → salary → category limits → plain spending.
/// Shared by Início and the widgets so both always show the same number.
struct SobraFigures {
    let title: String
    let amount: Money
    /// Cap, expected income or sum of limits; nil = compare with the previous cycle instead.
    let baseline: Money?
    let spent: Money
    let counted: [Movement]
    let previous: [Movement]
    let caption: String?
    let captionSymbol: String

    var isSobra: Bool { baseline != nil }

    @MainActor
    static func make(math: CategoryMath, cycle: PayCycle, mode: SobraMode, capCents: Int,
                     previousMovements: [Movement], context: ModelContext) -> SobraFigures {
        if mode == .cap, capCents > 0 {
            let cap = Money(cents: Int64(capCents))
            return SobraFigures(title: String(localized: "Sobra do mês"), amount: cap - math.totalSpent, baseline: cap, spent: math.totalSpent,
                                counted: math.movements, previous: [],
                                caption: String(localized: "Teto de \(cap.formattedWhole) · gasto \(math.totalSpent.formattedWhole)"),
                                captionSymbol: "gauge.with.needle")
        }
        if mode == .income {
            let expected = Ledger(context: context).salary(in: cycle.previous())
            let baseline = math.incomeBaseline(expectedSalary: expected)
            if baseline.cents > 0 {
                let caption = math.salaryReceived.cents > 0
                    ? String(localized: "Salário recebido: \(math.salaryReceived.formattedWhole)")
                    : (expected.cents > 0 ? String(localized: "Salário previsto: \(expected.formattedWhole) (ciclo anterior)") : nil)
                return SobraFigures(title: String(localized: "Sobra do mês"), amount: math.incomeSobra(expectedSalary: expected), baseline: baseline,
                                    spent: math.totalSpent, counted: math.movements, previous: [], caption: caption, captionSymbol: "briefcase")
            }
        }
        if math.hasLimits {
            return SobraFigures(title: String(localized: "Sobra do mês"), amount: math.sobra, baseline: math.totalLimit, spent: math.spentInLimited,
                                counted: math.limitedMovements, previous: [], caption: nil, captionSymbol: "chart.pie")
        }
        return SobraFigures(title: String(localized: "Gasto no ciclo"), amount: math.totalSpent, baseline: nil, spent: math.totalSpent,
                            counted: math.movements, previous: previousMovements.filter(\.countsAsSpending),
                            caption: mode == .income ? String(localized: "Marque seu salário para ver quanto sobra") : nil,
                            captionSymbol: "briefcase")
    }
}
