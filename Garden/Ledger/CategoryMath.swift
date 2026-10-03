import Foundation

/// Pure arithmetic over a cycle's movements (DESIGN §7). Categories are the budgets: each one may carry
/// a limit. Kept free of SwiftData queries so the widget and the app compute the same numbers.
struct CategoryMath {
    let cycle: PayCycle
    let categories: [SpendCategory]
    /// Spending in the cycle (expenses not transferred, refunded away or tombstoned).
    let movements: [Movement]
    /// This cycle's income (salary, other regular income); renda extra stays out of the baseline.
    let incomes: [Movement]

    init(cycle: PayCycle, categories: [SpendCategory], movements: [Movement]) {
        self.cycle = cycle
        self.categories = categories
        self.movements = movements.filter { cycle.contains($0.date) && $0.countsAsSpending }
        self.incomes = movements.filter {
            cycle.contains($0.date) && $0.kind == .income && $0.amountCents > 0 && $0.status != .tombstoned
        }
    }

    struct Line: Identifiable {
        /// nil = "Sem categoria".
        let category: SpendCategory?
        let spent: Money
        var id: String { category?.key ?? "_none" }
        var limit: Money? { category?.limit }
        var remaining: Money? { limit.map { $0 - spent } }
        var fraction: Double {
            guard let limit, limit.cents > 0 else { return 0 }
            return Double(spent.cents) / Double(limit.cents)
        }
        var isOver: Bool { limit.map { spent > $0 } ?? false }
        var name: String { category?.name ?? String(localized: "Sem categoria") }
        var symbol: String { category?.symbol ?? "questionmark" }
        var tint: CategoryTint { category?.tint ?? .gray }
    }

    private var spentByCategory: [String: Int64] {
        movements.reduce(into: [:]) { totals, movement in
            totals[movement.category?.key ?? "_none", default: 0] += movement.netCost.magnitude.cents
        }
    }

    /// Every category with spending or a limit, biggest spending first (the WalletPal-style breakdown).
    var lines: [Line] {
        let totals = spentByCategory
        var lines = categories
            .filter { !$0.isIncomeOrTransfer && ((totals[$0.key] ?? 0) > 0 || $0.limitCents > 0) }
            .map { Line(category: $0, spent: Money(cents: totals[$0.key] ?? 0)) }
        if let uncategorized = totals["_none"], uncategorized > 0 {
            lines.append(Line(category: nil, spent: Money(cents: uncategorized)))
        }
        return lines.sorted { $0.spent > $1.spent }
    }

    /// Categories with a limit, closest to (or over) it first.
    var limited: [Line] { lines.filter { $0.limit != nil }.sorted { $0.fraction > $1.fraction } }

    var totalSpent: Money { Money(cents: movements.reduce(0) { $0 + $1.netCost.magnitude.cents }) }
    var totalLimit: Money { Money(cents: categories.filter { !$0.isIncomeOrTransfer }.reduce(0) { $0 + $1.limitCents }) }
    var spentInLimited: Money { limited.reduce(.zero) { $0 + $1.spent } }
    var hasLimits: Bool { totalLimit.cents > 0 }
    var limitedMovements: [Movement] { movements.filter { ($0.category?.limitCents ?? 0) > 0 } }

    /// Plan mode: Σ category limits − spent in those categories.
    var sobra: Money { totalLimit - spentInLimited }

    func remaining(in category: SpendCategory) -> Money? {
        category.limit.map { $0 - Money(cents: spentByCategory[category.key] ?? 0) }
    }

    // MARK: Income mode — "quanto entrou de salário menos o que já gastei"

    var salaryReceived: Money { Money(cents: incomes.filter(\.isSalary).reduce(0) { $0 + $1.amountCents }) }
    var otherIncome: Money { Money(cents: incomes.filter { !$0.isSalary }.reduce(0) { $0 + $1.amountCents }) }

    /// Before this cycle's salary lands, last cycle's salary stands in for it.
    func incomeBaseline(expectedSalary: Money) -> Money {
        Money(cents: max(salaryReceived.cents, expectedSalary.cents)) + otherIncome
    }

    func incomeSobra(expectedSalary: Money) -> Money {
        incomeBaseline(expectedSalary: expectedSalary) - totalSpent
    }
}
