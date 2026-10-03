import SwiftData
import SwiftUI

/// "N pra conferir" (FLOWS F4). "Tudo certo" accepts only high-confidence rows — never
/// something the user hasn't looked at (REVIEW U2). Every row opens its detail.
struct ReviewView: View {
    @Query(filter: #Predicate<Movement> { !$0.reviewed }, sort: \Movement.date, order: .reverse)
    private var items: [Movement]
    @Query(sort: \SpendCategory.sortOrder) private var categories: [SpendCategory]
    @Environment(\.modelContext) private var context
    @State private var acceptedCount = 0

    private var visible: [Movement] { items.filter { !$0.isHiddenFromLists } }

    private var confident: [Movement] {
        visible.filter { $0.kind != .expense || ($0.categoryConfidence >= 0.8 && $0.category != nil) }
    }

    private var needsYou: [Movement] {
        let confidentIDs = Set(confident.map(\.id))
        return visible.filter { !confidentIDs.contains($0.id) }
    }

    var body: some View {
        List {
            if !needsYou.isEmpty {
                Section {
                    ForEach(needsYou) { movement in
                        ReviewRow(movement: movement, suggestions: suggestions(for: movement))
                    }
                } header: {
                    Text("Precisam de você")
                } footer: {
                    Text("Toque na categoria certa. O Garden lembra a escolha para esse estabelecimento.")
                }
            }

            if !confident.isEmpty {
                Section {
                    ForEach(confident) { movement in
                        NavigationLink(value: movement) {
                            MovementRowContent(movement: movement)
                        }
                    }
                } header: {
                    Text("Parecem certas")
                } footer: {
                    Button {
                        Ledger(context: context).markReviewed(confident)
                        acceptedCount += 1
                    } label: {
                        Text("Tudo certo (\(confident.count))")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .padding(.top, 8)
                }
            }
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView("Tudo conferido", systemImage: "checkmark.circle",
                                       description: Text("Novas movimentações aparecem aqui quando o Garden não tiver certeza."))
            }
        }
        .navigationTitle("Pra conferir")
        .sensoryFeedback(.success, trigger: acceptedCount)
    }

    /// The likely category first (current guess, merchant memory), then the most used ones.
    private func suggestions(for movement: Movement) -> [SpendCategory] {
        let expense = categories.filter { !$0.isIncomeOrTransfer }
        let usage = Dictionary(grouping: expense) { $0.key }.mapValues { ($0.first?.movements ?? []).count }
        let popular = expense.sorted { (usage[$0.key] ?? 0) > (usage[$1.key] ?? 0) }
        let first = [movement.category, movement.merchant?.category].compactMap { $0 }.filter { !$0.isIncomeOrTransfer }
        var seen = Set<String>()
        return (first + popular).filter { seen.insert($0.key).inserted }
    }
}

private struct ReviewRow: View {
    let movement: Movement
    let suggestions: [SpendCategory]
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: movement) {
                HStack {
                    MovementRowContent(movement: movement)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if movement.kind == .expense {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(suggestions.prefix(4)) { category in
                            Button {
                                Ledger(context: context).setCategory(category, for: movement)
                            } label: {
                                Label(category.name, systemImage: category.symbol)
                            }
                            .tint(category.tint.color)
                        }
                        Menu("Outra") {
                            ForEach(suggestions.dropFirst(4)) { category in
                                Button(category.name, systemImage: category.symbol) {
                                    Ledger(context: context).setCategory(category, for: movement)
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
                .scrollIndicators(.hidden)
                .controlSize(.small)
            } else {
                Button("Conferido", systemImage: "checkmark") {
                    Ledger(context: context).markReviewed([movement])
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
