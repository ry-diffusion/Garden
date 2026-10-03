import SwiftData
import SwiftUI

/// Movimentações: every movement grouped by day (FLOWS F5, F6).
struct MovementsView: View {
    @Query(sort: \Movement.date, order: .reverse) private var movements: [Movement]
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if movements.isEmpty {
                ContentUnavailableView {
                    Label("Nenhuma movimentação", systemImage: "tray")
                } description: {
                    Text("Lance um gasto agora ou ative as automações do Apple Pay e das notificações do banco em Ajustes.")
                } actions: {
                    Button("Lançar") { router.presentAdd() }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            } else {
                MovementList(movements: movements)
            }
        }
        .navigationTitle("Extrato")
        .toolbar { RootToolbar() }
    }
}

struct MovementList: View {
    let movements: [Movement]
    var showsSummary = true

    var body: some View {
        List {
            if showsSummary {
                CycleSummary(movements: movements)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            ForEach(groupedByDay, id: \.day) { group in
                Section {
                    ForEach(group.movements) { movement in
                        MovementRow(movement: movement)
                    }
                } header: {
                    HStack {
                        Text(group.day.dayHeader)
                        Spacer()
                        if group.spent.cents > 0 {
                            Text(group.spent.formatted)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listSectionSpacing(.compact)
        #endif
        .navigationDestination(for: Movement.self) { MovementDetailView(movement: $0) }
        .refreshable { await SyncEngine.shared.sync() }
    }

    private struct DayGroup {
        let day: Date
        let movements: [Movement]
        var spent: Money { movements.filter(\.countsAsSpending).reduce(.zero) { $0 + $1.netCost.magnitude } }
    }

    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.brazil
        // A transfer between my accounts is one event: show the outgoing side ("BTG → Nubank") only.
        let visible = movements.filter { !$0.isHiddenFromLists }
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { DayGroup(day: $0, movements: groups[$0] ?? []) }
    }
}

/// "Neste ciclo": spent · received · moved between my accounts.
private struct CycleSummary: View {
    let movements: [Movement]
    @AppStorage(Preferences.paydayKey) private var payday = PayCycle.defaultPayday

    var body: some View {
        let cycle = PayCycle(containing: .now, payday: payday)
        let inCycle = movements.filter { cycle.contains($0.date) && $0.status != .tombstoned }
        let spent = inCycle.filter(\.countsAsSpending).reduce(Money.zero) { $0 + $1.netCost.magnitude }
        let received = inCycle.filter { $0.kind == .income || $0.kind == .extraIncome }.reduce(Money.zero) { $0 + $1.amount }
        let moved = inCycle.filter { $0.kind == .transfer && $0.amountCents < 0 }.reduce(Money.zero) { $0 + $1.amount.magnitude }

        HStack(spacing: 10) {
            SummaryTile(title: "Saiu", value: spent, symbol: "arrow.up.right", tint: .primary)
            SummaryTile(title: "Entrou", value: received, symbol: "arrow.down.left", tint: .green)
            if moved.cents > 0 {
                SummaryTile(title: "Transferido", value: moved, symbol: "arrow.left.arrow.right", tint: .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SummaryTile: View {
    let title: LocalizedStringKey
    let value: Money
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            Text(value.formattedWhole)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Row

struct MovementRow: View {
    let movement: Movement
    @Environment(\.modelContext) private var context
    @Query(sort: \SpendCategory.sortOrder) private var categories: [SpendCategory]
    @State private var suggestedPayday: Int?

    var body: some View {
        NavigationLink(value: movement) {
            HStack(alignment: .center, spacing: 12) {
                MovementRowContent(movement: movement, showsAmount: false)
                VStack(alignment: .trailing, spacing: 4) {
                    AmountText(movement: movement)
                        .font(.body.weight(.medium))
                    if movement.kind == .expense {
                        CategoryPill(movement: movement, categories: categories)
                    }
                }
            }
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .contextMenu { contextMenu }
        .paydaySuggestion($suggestedPayday)
        .swipeActions(edge: .leading) {
            if !movement.reviewed {
                Button("Conferido", systemImage: "checkmark") { ledger.markReviewed([movement]) }
                    .tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Apagar", systemImage: "trash", role: .destructive) { ledger.delete(movement) }
        }
    }

    private var ledger: Ledger { Ledger(context: context) }
    private var payerName: String? { movement.merchant?.displayName ?? movement.person?.displayName }

    @ViewBuilder private var contextMenu: some View {
        if movement.amountCents > 0, movement.kind != .transfer {
            Section(payerName.map { "Pagamentos de \($0)" } ?? "Entrada") {
                if movement.isSalary || movement.isFromSalarySource {
                    Button("Não é salário", systemImage: "briefcase") { ledger.setSalary(false, for: movement) }
                } else {
                    Button("Marcar como salário", systemImage: "briefcase") {
                        suggestedPayday = ledger.setSalary(true, for: movement)
                    }
                }
                Button(movement.kind == .extraIncome ? "Renda normal" : "Renda extra (13º, PLR, bônus)", systemImage: "sparkle") {
                    movement.kind = movement.kind == .extraIncome ? .income : .extraIncome
                    movement.userEdited = true
                    ledger.save()
                }
            }
        }
        // F6: one tap to make the current category stick to this merchant; any other one level down.
        if let merchant = movement.merchant, movement.kind == .expense {
            Section("Sempre para \(merchant.displayName)") {
                if let current = movement.category, merchant.category !== current {
                    Button("Sempre \(current.name)", systemImage: current.symbol) {
                        ledger.alwaysCategory(current, for: merchant)
                    }
                }
                Menu("Outra categoria…", systemImage: "square.grid.2x2") {
                    ForEach(expenseCategories) { category in
                        Button(category.name, systemImage: category.symbol) { ledger.alwaysCategory(category, for: merchant) }
                    }
                }
            }
        }
        if !movement.reviewed {
            Button("Marcar como conferido", systemImage: "checkmark") { ledger.markReviewed([movement]) }
        }
        Button("Apagar", systemImage: "trash", role: .destructive) { ledger.delete(movement) }
    }

    private var expenseCategories: [SpendCategory] { categories.filter { !$0.isIncomeOrTransfer } }
}

/// Icon, title and subtitle — shared by lists, search and the Home "Recentes" card.
struct MovementRowContent: View {
    let movement: Movement
    /// Lists show the amount and category pill beside this; compact cards fold the category into the subtitle.
    var showsAmount = true
    /// Inside a category's own screen its name would only repeat.
    var showsCategory = true

    var body: some View {
        HStack(spacing: 12) {
            MovementBadge(movement: movement)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(movement.displayTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let kind = movement.merchant?.kind, kind != .local {
                        Text(kind.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if showsAmount {
                AmountText(movement: movement)
                    .font(.body.weight(.medium))
            }
        }
        .contentShape(.rect)
    }

    private var subtitle: String {
        var parts: [String] = []
        if movement.kind == .transfer {
            parts.append(MovementKind.transfer.label)
        } else if showsCategory && (showsAmount || movement.kind != .expense) {
            parts.append(movement.category?.name ?? String(localized: "Sem categoria"))
        }
        if let installment = movement.installmentNumber, let count = movement.installmentPlan?.count {
            parts.append("\(installment)/\(count)")
        }
        if let method = movement.paymentMethodLabel { parts.append(method) }
        if let memo = movement.note.isEmpty ? nil : movement.note, movement.kind == .income {
            parts.append(memo)
        } else if let account = movement.account {
            parts.append(account.institution.isEmpty ? account.name : account.institution)
        } else if let bank = movement.cardName {
            parts.append(bank)
        }
        return parts.joined(separator: " · ")
    }
}

extension Movement {
    /// "Débito", "Crédito", "Pix", "Boleto" — from the bank's operation, the account, or the capture source.
    var paymentMethodLabel: String? {
        let operation = (MerchantRules.splitOperation(rawDescription).operation ?? "").normalizedForMatching
        if operation.contains("DEBITO") || self.operationType == "CARTAO" { return String(localized: "Débito") }
        if operation.contains("CREDITO") || account?.kind == .credit { return String(localized: "Crédito") }
        if operation.contains("PIX") || self.operationType == "PIX" { return "Pix" }
        if operation.contains("BOLETO") || self.operationType == "BOLETO" { return String(localized: "Boleto") }
        if source == .applePay { return "Apple Pay" }
        return nil
    }
}

// MARK: - Category pill (F5: 2 taps)

struct CategoryPill: View {
    let movement: Movement
    let categories: [SpendCategory]
    @Environment(\.modelContext) private var context

    var body: some View {
        Menu {
            Picker("Categoria", selection: selection) {
                ForEach(categories.filter { !$0.isIncomeOrTransfer }) { category in
                    Label(category.name, systemImage: category.symbol).tag(SpendCategory?.some(category))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(movement.category?.name ?? String(localized: "Categorizar"))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(pillTint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(pillTint.opacity(0.14), in: .capsule)
                .frame(minHeight: 28)
                .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Categoria: \(movement.category?.name ?? String(localized: "Sem categoria"))")
        .sensoryFeedback(.selection, trigger: movement.category?.key)
    }

    private var pillTint: Color { movement.category?.tint.color ?? .orange }

    private var selection: Binding<SpendCategory?> {
        Binding(get: { movement.category }, set: { Ledger(context: context).setCategory($0, for: movement) })
    }
}
