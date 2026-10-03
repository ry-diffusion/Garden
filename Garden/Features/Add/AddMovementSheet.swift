import SwiftData
import SwiftUI

/// Lançar (FLOWS F1): open → type amount → tap a merchant chip = saved. Two taps.
struct AddMovementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var merchants: [Merchant]

    @AppStorage("lastAccountID") private var lastAccountID = ""
    @State private var amountText = ""
    @State private var merchantText = ""
    @State private var kind: MovementKind = .expense
    @State private var account: Account?
    @State private var date = Date.now
    /// Frozen on appear so chips never shift under a finger (REVIEW U4).
    @State private var chipSnapshot: [Merchant] = []
    @State private var savedCount = 0
    @FocusState private var focus: Field?

    private enum Field { case amount, merchant }

    private var amount: Money? {
        guard let money = Money(parsing: amountText), money.cents != 0 else { return nil }
        return money.magnitude
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Tipo", selection: $kind) {
                        Text("Gasto").tag(MovementKind.expense)
                        Text("Entrada").tag(MovementKind.income)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("R$")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        TextField("0,00", text: $amountText)
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .fixedSize()
                            .focused($focus, equals: .amount)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .accessibilityLabel("Valor")
                    }
                    .foregroundStyle(kind == .income ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                    .onTapGesture { focus = .amount }

                    HStack(spacing: 8) {
                        accountMenu
                        DatePicker("Data", selection: $date, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }

                    TextField(kind == .expense ? "Onde? (opcional)" : "De quem? (opcional)", text: $merchantText)
                        .focused($focus, equals: .merchant)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .padding(14)
                        .background(Color.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))

                    if !visibleChips.isEmpty {
                        chips
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.never)
            .background(Color.groupedBackground)
            .navigationTitle("Lançar")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar", action: save)
                        .disabled(amount == nil)
                }
            }
            .onAppear(perform: prepare)
            .sensoryFeedback(.success, trigger: savedCount)
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    // MARK: Pieces

    private var accountMenu: some View {
        Menu {
            Picker("Conta", selection: $account) {
                ForEach(accounts) { Label($0.name, systemImage: $0.kind.symbol).tag(Account?.some($0)) }
            }
        } label: {
            Label(account?.name ?? String(localized: "Conta"), systemImage: account?.kind.symbol ?? "building.columns")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.cardBackground, in: .capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var visibleChips: [Merchant] {
        // Payers for Entrada, shops for Gasto — filtering keeps the order stable.
        let wantsIncome = kind == .income
        let byKind = chipSnapshot.filter { merchant in
            (merchant.movements ?? []).contains { ($0.amountCents > 0) == wantsIncome && $0.kind != .transfer }
        }
        let query = merchantText.normalizedForMatching
        guard !query.isEmpty else { return byKind }
        return byKind.filter { $0.displayName.normalizedForMatching.contains(query) }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recentes")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(visibleChips) { merchant in
                    Button {
                        merchantText = merchant.displayName
                        if amount != nil { save() } else { focus = .amount }
                    } label: {
                        HStack(spacing: 8) {
                            MerchantBadge(domain: merchant.domain, symbol: chipSymbol(for: merchant),
                                          tint: chipTint(for: merchant), size: 22)
                            Text(merchant.displayName)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.leading, 6)
                        .padding(.trailing, 12)
                        .padding(.vertical, 9)
                        .background(Color.cardBackground, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipTint(for merchant: Merchant) -> Color {
        let latest = merchant.movements?.max { $0.date < $1.date }
        return (merchant.category ?? latest?.category)?.tint.color ?? .secondary
    }

    private func chipSymbol(for merchant: Merchant) -> String {
        let latest = merchant.movements?.max { $0.date < $1.date }
        return merchant.category?.symbol ?? latest?.category?.symbol ?? "storefront"
    }

    // MARK: Actions

    private func prepare() {
        account = accounts.first { $0.id.uuidString == lastAccountID }
            ?? accounts.first { $0.kind == .cash }
            ?? accounts.first
        let recent = merchants
            .map { merchant in (merchant, merchant.movements?.map(\.date).max() ?? merchant.createdAt) }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map(\.0)
        chipSnapshot = Array(recent)
        focus = .amount
    }

    private func save() {
        guard let amount else {
            focus = .amount
            return
        }
        let name = merchantText.trimmingCharacters(in: .whitespacesAndNewlines)
        Ledger(context: context).addManual(amount: amount, kind: kind, merchantName: name.isEmpty ? nil : name,
                                           account: account, date: date)
        if let account { lastAccountID = account.id.uuidString }
        savedCount += 1
        dismiss()
    }
}

/// Wrapping row of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
