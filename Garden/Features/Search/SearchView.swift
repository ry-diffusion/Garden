import SwiftData
import SwiftUI

/// Buscar (FLOWS F14): "ifood" → a summary of what you spent there, then the matching movements.
struct SearchView: View {
    @Query(sort: \Movement.date, order: .reverse) private var movements: [Movement]
    @State private var query = ""
    /// What we actually search for: `query` after 250 ms without typing, so filtering thousands of
    /// rows doesn't run on every keystroke.
    @State private var debouncedQuery = ""

    var body: some View {
        List {
            if !trimmed.isEmpty, !results.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(spent.formatted)
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section("Resultados") {
                    ForEach(results) { MovementRow(movement: $0) }
                }
            }
        }
        .overlay {
            if trimmed.isEmpty {
                ContentUnavailableView("Buscar movimentações", systemImage: "magnifyingglass",
                                       description: Text("Procure por estabelecimento, pessoa, categoria, conta ou nota."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Buscar")
        .navigationDestination(for: Movement.self) { MovementDetailView(movement: $0) }
        .searchable(text: $query, prompt: "Estabelecimento, pessoa, categoria…")
        .task(id: query) {
            if query.isEmpty {
                debouncedQuery = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            debouncedQuery = query
        }
    }

    private var trimmed: String { debouncedQuery.trimmingCharacters(in: .whitespaces) }

    private var results: [Movement] {
        let needle = trimmed.normalizedForMatching
        guard !needle.isEmpty else { return [] }
        return movements.filter { !$0.isHiddenFromLists }.filter { movement in
            [movement.displayTitle, movement.rawDescription, movement.note,
             movement.category?.name ?? "", movement.account?.name ?? ""]
                .contains { $0.normalizedForMatching.contains(needle) }
        }
    }

    private var spent: Money {
        results.filter(\.countsAsSpending).reduce(.zero) { $0 + $1.netCost.magnitude }
    }

    private var summary: String {
        let cycle = Preferences.currentCycle
        let inCycle = results.filter { cycle.contains($0.date) && $0.countsAsSpending }
        let cycleSpent = inCycle.reduce(Money.zero) { $0 + $1.netCost.magnitude }
        let count = results.count == 1 ? "1 movimentação" : "\(results.count) movimentações"
        return "\(count) no total · \(cycleSpent.formattedWhole) neste ciclo"
    }
}
