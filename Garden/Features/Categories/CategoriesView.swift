import SwiftData
import SwiftUI

/// Categorias: where the money went this cycle (WalletPal-style ring) and an optional limit per
/// category — categories are the budgets (DESIGN §7).
struct CategoriesView: View {
    @AppStorage(Preferences.paydayKey) private var payday = PayCycle.defaultPayday

    var body: some View {
        let cycle = PayCycle(containing: .now, payday: payday)
        CategoriesContent(cycle: cycle)
            .id(cycle)
            .navigationTitle("Categorias")
            .toolbar { RootToolbar() }
    }
}

private struct CategoriesContent: View {
    let cycle: PayCycle
    @AppStorage(Preferences.monthlyCapKey) private var capCents = 0
    @Query(sort: \SpendCategory.sortOrder) private var categories: [SpendCategory]
    @Query private var cycleMovements: [Movement]

    init(cycle: PayCycle) {
        self.cycle = cycle
        let start = cycle.start, end = cycle.end
        _cycleMovements = Query(filter: #Predicate<Movement> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        let math = CategoryMath(cycle: cycle, categories: categories, movements: cycleMovements)
        let lines = math.lines
        List {
            Section {
                VStack(spacing: 16) {
                    SpendingRing(lines: lines, total: math.totalSpent)
                        .frame(height: 210)
                    Text(cycleLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let cap = Preferences.monthlyCap, capCents > 0 {
                        VStack(spacing: 6) {
                            Text("\(math.totalSpent.formattedWhole) de \(cap.formattedWhole) do teto do mês")
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                            BudgetBar(fraction: Double(math.totalSpent.cents) / Double(cap.cents), pace: cycle.elapsedFraction(), height: 8)
                        }
                    }
                    if math.hasLimits {
                        Text("\(math.spentInLimited.formattedWhole) de \(math.totalLimit.formattedWhole) nos limites das categorias")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if lines.isEmpty {
                ContentUnavailableView("Nenhum gasto neste ciclo", systemImage: "chart.pie",
                                       description: Text("Os gastos aparecem aqui por categoria assim que forem registrados."))
                    .listRowBackground(Color.clear)
            } else {
                Section("Neste ciclo") {
                    ForEach(lines) { line in
                        NavigationLink(value: line.category.map(Route.category) ?? Route.uncategorized) {
                            CategoryLineRow(line: line, share: share(line, of: math.totalSpent), pace: cycle.elapsedFraction())
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                    }
                }
            }

            let others = categories.filter { category in
                !category.isIncomeOrTransfer && !lines.contains { $0.category === category }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { category in
                        NavigationLink(value: Route.category(category)) {
                            Label(category.name, systemImage: category.symbol)
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("Sem gastos neste ciclo")
                } footer: {
                    Text("Toque numa categoria para definir um limite por ciclo.")
                }
            }
        }
    }

    private func share(_ line: CategoryMath.Line, of total: Money) -> Double {
        total.cents > 0 ? Double(line.spent.cents) / Double(total.cents) : 0
    }

    private var cycleLabel: String {
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(Money.brazil)
        let last = Calendar.brazil.date(byAdding: .day, value: -1, to: cycle.end) ?? cycle.end
        return "\(cycle.start.formatted(format)) – \(last.formatted(format)) · \(cycle.daysRemaining()) dias restantes"
    }
}

/// One category: icon, spent, share of the cycle — and, with a limit, what's left and a pace bar.
struct CategoryLineRow: View {
    let line: CategoryMath.Line
    let share: Double
    let pace: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SymbolBadge(symbol: line.symbol, tint: line.tint.color, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(line.isOver ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(line.spent.formattedWhole)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                    Text(share, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .fixedSize()
            }
            if line.limit != nil {
                BudgetBar(fraction: line.fraction, pace: pace, tint: line.tint.color)
            } else {
                BudgetBar(fraction: share, tint: line.tint.color.opacity(0.55), height: 4)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        guard let limit = line.limit, let remaining = line.remaining else {
            return line.category == nil ? String(localized: "Toque para categorizar") : String(localized: "Sem limite")
        }
        return line.isOver
            ? "\(remaining.magnitude.formattedWhole) acima de \(limit.formattedWhole)"
            : "\(remaining.formattedWhole) restantes de \(limit.formattedWhole)"
    }
}

// MARK: - Category detail: the limit lives here

struct CategoryDetailView: View {
    @Bindable var category: SpendCategory
    let cycle: PayCycle
    @Environment(\.modelContext) private var context
    @State private var limitText = ""
    @State private var suggestion: Money?
    @FocusState private var limitFocused: Bool

    var body: some View {
        let movements = cycleMovements
        let spent = movements.reduce(Money.zero) { $0 + $1.netCost.magnitude }
        Form {
            Section {
                VStack(spacing: 6) {
                    SymbolBadge(symbol: category.symbol, tint: category.tint.color, size: 56)
                    Text(spent.formattedWhole)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    Text(category.limit.map { "de \($0.formattedWhole) neste ciclo" } ?? String(localized: "gasto neste ciclo"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let limit = category.limit {
                        BudgetBar(fraction: limit.cents > 0 ? Double(spent.cents) / Double(limit.cents) : 0,
                                  pace: cycle.elapsedFraction(), tint: category.tint.color, height: 8)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Limite por ciclo") {
                    TextField("Sem limite", text: $limitText)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($limitFocused)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .onSubmit(saveLimit)
                        .onChange(of: limitFocused) { _, focused in if !focused { saveLimit() } }
                }
                if let suggestion, category.limit == nil {
                    Button("Usar \(suggestion.formattedWhole) (média dos últimos 3 ciclos)") {
                        Ledger(context: context).setLimit(suggestion, for: category)
                        limitText = suggestion.formatted
                    }
                }
                if category.limit != nil {
                    Toggle("Acumular o que sobrar", isOn: $category.rollover)
                    Button("Remover limite", role: .destructive) {
                        Ledger(context: context).setLimit(nil, for: category)
                        limitText = ""
                    }
                }
            } header: {
                Text("Limite")
            } footer: {
                Text("O limite vale do dia do pagamento até o próximo. Sem limite, a categoria só aparece no gráfico.")
            }

            if let merchants = category.merchants?.filter({ !($0.movements ?? []).isEmpty }), !merchants.isEmpty {
                Section("Estabelecimentos que entram aqui") {
                    ForEach(merchants.sorted { $0.displayName < $1.displayName }) { merchant in
                        Text(merchant.displayName)
                    }
                }
            }

            Section("Neste ciclo") {
                if movements.isEmpty {
                    Text("Nenhum gasto ainda").foregroundStyle(.secondary)
                }
                ForEach(movements) { movement in
                    NavigationLink(value: movement) {
                        MovementRowContent(movement: movement, showsCategory: false)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(category.name)
        .onAppear {
            limitText = category.limit?.formatted ?? ""
            suggestion = Ledger(context: context).suggestedLimit(for: category, before: cycle)
        }
    }

    private var cycleMovements: [Movement] {
        let start = cycle.start, end = cycle.end, key = category.key
        let all = (try? context.fetch(FetchDescriptor<Movement>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))) ?? []
        return all.filter { $0.countsAsSpending && $0.category?.key == key }
    }

    private func saveLimit() {
        let parsed = Money(parsing: limitText)
        Ledger(context: context).setLimit(parsed?.magnitude, for: category)
    }
}

/// Spending without a category — the list to work through.
struct UncategorizedView: View {
    let cycle: PayCycle
    @Query(sort: \Movement.date, order: .reverse) private var movements: [Movement]

    var body: some View {
        List {
            ForEach(movements.filter { cycle.contains($0.date) && $0.countsAsSpending && $0.category == nil }) {
                MovementRow(movement: $0)
            }
        }
        .navigationTitle("Sem categoria")
    }
}
