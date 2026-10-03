import SwiftData
import SwiftUI

/// Meu dinheiro: patrimônio, contas, investimentos (DESIGN §10, FLOWS F12).
struct MoneyView: View {
    @Query(filter: #Predicate<Account> { !$0.isArchived }, sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var holdings: [Holding]
    @State private var editing: Account?
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Patrimônio")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(netWorth.formattedWhole)
                        .font(.system(.largeTitle, weight: .bold))
                        .monospacedDigit()
                        .accessibilityAddTraits(.isHeader)
                    Text("Ativos \(assets.formattedWhole) · Dívidas \(liabilities.formattedWhole)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
            }

            if !holdings.isEmpty {
                Section("Investido") {
                    LabeledContent("Total") { Text(invested.formattedWhole).monospacedDigit() }
                    LabeledContent("Disponível hoje") { Text(liquid.formattedWhole).monospacedDigit() }
                    ForEach(holdings.sorted { $0.netCents > $1.netCents }) { holding in
                        LabeledContent {
                            Text(Money(cents: holding.netCents).formattedWhole).monospacedDigit()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(holding.name)
                                Text(holding.dailyLiquidity
                                     ? String(localized: "Liquidez diária")
                                     : holding.liquidityDate.map { "Resgate a partir de \($0.formatted(.dateTime.day().month().year().locale(Money.brazil)))" } ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Contas") {
                ForEach(accounts) { account in
                    Button { editing = account } label: {
                        HStack(spacing: 12) {
                            SymbolBadge(symbol: account.kind.symbol, tint: .accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(subtitle(for: account))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(account.currentBalance.formatted)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(account.kind.isLiability ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button("Adicionar conta", systemImage: "plus") { isAdding = true }
            }
        }
        .navigationTitle("Patrimônio")
        .toolbar { RootToolbar() }
        .sheet(item: $editing) { AccountEditor(account: $0) }
        .sheet(isPresented: $isAdding) { AccountEditor(account: nil) }
    }

    /// "Cartão de crédito" — the institution is dropped when the account name already says it.
    private func subtitle(for account: Account) -> String {
        let institution = account.institution
        if institution.isEmpty || account.name.normalizedForMatching.contains(institution.normalizedForMatching) {
            return account.kind.label
        }
        return "\(institution) · \(account.kind.label)"
    }

    private var invested: Money { Money(cents: holdings.reduce(0) { $0 + $1.netCents }) }
    private var liquid: Money { Money(cents: holdings.filter(\.dailyLiquidity).reduce(0) { $0 + $1.netCents }) }

    /// Holdings count once: through their account when they have one, directly otherwise.
    private var assets: Money {
        let unattached = Money(cents: holdings.filter { $0.account == nil }.reduce(0) { $0 + $1.netCents })
        return accounts.filter { !$0.kind.isLiability }.reduce(unattached) { $0 + $1.currentBalance }
    }

    private var liabilities: Money {
        accounts.filter(\.kind.isLiability).reduce(.zero) { $0 + $1.currentBalance.magnitude }
    }

    private var netWorth: Money { assets - liabilities }
}

extension Account {
    /// Manual and cash accounts move with their movements; connected accounts report their own balance.
    var currentBalance: Money {
        let holdingsTotal = (holdings ?? []).reduce(Int64(0)) { $0 + $1.netCents }
        guard pluggyAccountId == nil else { return Money(cents: balanceCents + holdingsTotal, currency: currency) }
        let movementsTotal = (movements ?? [])
            .filter { $0.status != .tombstoned }
            .reduce(Int64(0)) { $0 + $1.amountCents }
        return Money(cents: balanceCents + movementsTotal + holdingsTotal, currency: currency)
    }
}

// MARK: - Account editor

struct AccountEditor: View {
    let account: Account?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var institution = "Nubank"
    @State private var kind: AccountKind = .checking
    @State private var openingText = ""

    private let institutions = ["Nubank", "Inter", "BTG Pactual", "Itaú", "Bradesco", "Caixa", "Banco do Brasil", "Santander", "C6", "Outro"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome", text: $name, prompt: Text("Ex.: Nubank crédito"))
                Picker("Instituição", selection: $institution) {
                    ForEach(institutions, id: \.self) { Text($0) }
                }
                Picker("Tipo", selection: $kind) {
                    ForEach(AccountKind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                LabeledContent(kind.isLiability ? "Fatura atual" : "Saldo inicial") {
                    TextField("R$ 0,00", text: $openingText)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                }
                if let account {
                    Section {
                        Button("Arquivar conta", role: .destructive) {
                            account.isArchived = true
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(account == nil ? "Nova conta" : "Editar conta")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let account else { return }
                name = account.name
                institution = account.institution
                kind = account.kind
                let opening = kind.isLiability ? -account.balance : account.balance
                openingText = account.balanceCents == 0 ? "" : opening.formatted
            }
        }
        .frame(minWidth: 380, minHeight: 360)
    }

    private func save() {
        let parsed = Money(parsing: openingText) ?? .zero
        // A card's open bill is a debt: stored negative so the balance arithmetic stays uniform.
        let opening = kind.isLiability ? -parsed.magnitude : parsed
        let target = account ?? {
            let new = Account(name: name, institution: institution, kind: kind)
            context.insert(new)
            return new
        }()
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.institution = institution
        target.kind = kind
        target.balanceCents = opening.cents
        try? context.save()
        dismiss()
    }
}
