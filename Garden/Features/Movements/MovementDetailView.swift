import MapKit
import SwiftData
import SwiftUI

/// Detail for one movement. Every action reachable by long-press or swipe also lives here
/// as a visible control (accessibility rule, DESIGN §15).
struct MovementDetailView: View {
    @Bindable var movement: Movement
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendCategory.sortOrder) private var categories: [SpendCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var isConfirmingDelete = false
    @State private var suggestedPayday: Int?

    private var ledger: Ledger { Ledger(context: context) }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    MovementBadge(movement: movement, size: 56)
                    Text(movement.displayTitle)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    AmountText(movement: movement)
                        .font(.system(.largeTitle, weight: .bold))
                    Text(movement.date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(Money.brazil)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                Picker("Categoria", selection: categoryBinding) {
                    Text("Sem categoria").tag(SpendCategory?.none)
                    ForEach(categories) { Label($0.name, systemImage: $0.symbol).tag(SpendCategory?.some($0)) }
                }
                Picker("Tipo", selection: $movement.kindRaw) {
                    ForEach(MovementKind.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Conta", selection: $movement.account) {
                    Text("Nenhuma").tag(Account?.none)
                    ForEach(accounts) { Text($0.name).tag(Account?.some($0)) }
                }
                DatePicker("Data", selection: $movement.date)
            }

            if movement.amountCents > 0, movement.kind != .transfer {
                Section {
                    Toggle(isOn: salaryBinding) {
                        Label("Salário", systemImage: "briefcase")
                    }
                } footer: {
                    if let payer = movement.merchant?.displayName ?? movement.person?.displayName {
                        Text(movement.isFromSalarySource
                             ? "Todo pagamento de \(payer) entra como salário."
                             : "Ative para que todo pagamento de \(payer) entre como salário.")
                    } else {
                        Text("Sem pagador identificado: vale só para esta entrada.")
                    }
                }
            }

            if let merchant = movement.merchant, movement.kind == .expense {
                Section {
                    Menu {
                        ForEach(categories.filter { !$0.isIncomeOrTransfer }) { category in
                            Button(category.name, systemImage: category.symbol) { ledger.alwaysCategory(category, for: merchant) }
                        }
                    } label: {
                        Label("Sempre usar uma categoria para \(merchant.displayName)", systemImage: "pin")
                    }
                } footer: {
                    if let category = merchant.category {
                        Text("Compras em \(merchant.displayName) entram em \(category.name).")
                    }
                }
            }

            Section("Nota") {
                TextField("Adicionar nota", text: $movement.note, axis: .vertical)
            }

            if let latitude = movement.latitude, let longitude = movement.longitude {
                Section("Local") {
                    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600))) {
                        Marker(movement.placeName ?? movement.displayTitle, systemImage: movement.category?.symbol ?? "mappin", coordinate: coordinate)
                    }
                    .frame(height: 160)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            }

            Section("Detalhes") {
                LabeledContent("Origem", value: movement.source.label)
                if movement.status == .provisional {
                    LabeledContent("Situação", value: String(localized: "Aguardando o banco"))
                }
                if !movement.rawDescription.isEmpty {
                    LabeledContent("Descrição original") {
                        Text(movement.rawDescription).textSelection(.enabled)
                    }
                }
                if let card = movement.cardName {
                    LabeledContent("Cartão ou banco", value: card)
                }
                if let merchant = movement.merchant {
                    if let legal = merchant.legalName { LabeledContent("Razão social") { Text(legal).textSelection(.enabled) } }
                    if let cnpj = merchant.cnpj { LabeledContent("CNPJ") { Text(cnpj).textSelection(.enabled) } }
                    if let address = merchant.address { LabeledContent("Endereço") { Text(address).textSelection(.enabled) } }
                }
            }

            Section {
                if !movement.reviewed {
                    Button("Marcar como conferido", systemImage: "checkmark") { ledger.markReviewed([movement]) }
                }
                Button("Apagar movimentação", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
            }
        }
        .formStyle(.grouped)
        .task {
            if let merchant = movement.merchant { await ledger.enrichFromRegistry(merchant) }
        }
        .navigationTitle(movement.displayTitle)
        .toolbarTitleDisplayMode(.inline)
        .paydaySuggestion($suggestedPayday)
        .confirmationDialog("Apagar esta movimentação?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Apagar", role: .destructive) {
                ledger.delete(movement)
                dismiss()
            }
        }
        .onChange(of: movement.kindRaw) { _, newValue in
            if newValue != MovementKind.expense.rawValue, movement.amountCents < 0,
               [MovementKind.income, .extraIncome, .refund].map(\.rawValue).contains(newValue) {
                movement.amountCents = -movement.amountCents
            }
            movement.userEdited = true
        }
    }

    private var salaryBinding: Binding<Bool> {
        Binding(
            get: { movement.isSalary || movement.isFromSalarySource },
            set: { suggestedPayday = ledger.setSalary($0, for: movement) }
        )
    }

    private var categoryBinding: Binding<SpendCategory?> {
        Binding(get: { movement.category }, set: { ledger.setCategory($0, for: movement) })
    }
}
