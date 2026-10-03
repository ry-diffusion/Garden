import SwiftData
import SwiftUI

/// Início: Sobra do mês, review queue, where the money went, recent movements (DESIGN §15, FLOWS F3/F4).
struct HomeView: View {
    @AppStorage(Preferences.paydayKey) private var payday = PayCycle.defaultPayday

    var body: some View {
        let cycle = PayCycle(containing: .now, payday: payday)
        HomeContent(cycle: cycle)
            .id(cycle)
            .navigationTitle("Início")
            .toolbar { RootToolbar() }
    }
}

private struct HomeContent: View {
    let cycle: PayCycle
    @AppStorage(Preferences.sobraModeKey) private var sobraMode: SobraMode = .plan
    @Environment(\.modelContext) private var context

    @Query(sort: \SpendCategory.sortOrder) private var categories: [SpendCategory]
    @Query private var cycleMovements: [Movement]
    @Query private var previousMovements: [Movement]
    @Query(filter: #Predicate<Movement> { !$0.reviewed }, sort: \Movement.date, order: .reverse)
    private var toReview: [Movement]
    @Query(sort: \Movement.date, order: .reverse) private var recent: [Movement]

    init(cycle: PayCycle) {
        self.cycle = cycle
        let start = cycle.start, end = cycle.end
        let previous = cycle.previous()
        let previousStart = previous.start, previousEnd = previous.end
        _cycleMovements = Query(filter: #Predicate<Movement> { $0.date >= start && $0.date < end })
        _previousMovements = Query(filter: #Predicate<Movement> { $0.date >= previousStart && $0.date < previousEnd })
        var recentDescriptor = FetchDescriptor<Movement>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        recentDescriptor.fetchLimit = 8
        _recent = Query(recentDescriptor)
    }

    var body: some View {
        let math = CategoryMath(cycle: cycle, categories: categories, movements: cycleMovements)
        let reviewCount = toReview.filter { !$0.isHiddenFromLists }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Money.brazil)).capitalizedSentence)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                SobraHero(figures: figures(math), cycle: cycle)

                if reviewCount > 0 {
                    NavigationLink(value: Route.review) {
                        ReviewCard(count: reviewCount)
                    }
                    .buttonStyle(.plain)
                }

                if !math.lines.isEmpty {
                    CategoriesCard(math: math, pace: cycle.elapsedFraction())
                }

                if !recent.isEmpty {
                    RecentSection(movements: Array(recent.filter { !$0.isHiddenFromLists }.prefix(5)))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .refreshable { await SyncEngine.shared.sync() }
        .background(Color.groupedBackground)
    }

    /// Income mode (salary) → plan mode (category limits) → plain "spent vs. last cycle".
    private func figures(_ math: CategoryMath) -> SobraFigures {
        let previousSpending = previousMovements.filter(\.countsAsSpending)
        if sobraMode == .income {
            let expected = Ledger(context: context).salary(in: cycle.previous())
            let baseline = math.incomeBaseline(expectedSalary: expected)
            if baseline.cents > 0 {
                let caption = math.salaryReceived.cents > 0
                    ? "Salário recebido: \(math.salaryReceived.formattedWhole)"
                    : (expected.cents > 0 ? "Salário previsto: \(expected.formattedWhole) (ciclo anterior)" : nil)
                return SobraFigures(title: "Sobra do mês", amount: math.incomeSobra(expectedSalary: expected), baseline: baseline,
                                    spent: math.totalSpent, counted: math.movements, previous: [], caption: caption)
            }
        }
        if math.hasLimits {
            return SobraFigures(title: "Sobra do mês", amount: math.sobra, baseline: math.totalLimit, spent: math.spentInLimited,
                                counted: math.limitedMovements, previous: [], caption: nil)
        }
        return SobraFigures(title: "Gasto no ciclo", amount: math.totalSpent, baseline: nil, spent: math.totalSpent,
                            counted: math.movements, previous: previousSpending,
                            caption: sobraMode == .income ? "Marque seu salário para ver quanto sobra" : nil)
    }
}

// MARK: - Hero

private struct SobraFigures {
    let title: LocalizedStringKey
    let amount: Money
    /// Limits or expected income; nil = compare with the previous cycle instead.
    let baseline: Money?
    let spent: Money
    let counted: [Movement]
    let previous: [Movement]
    let caption: String?

    var isSobra: Bool { baseline != nil }
}

private struct SobraHero: View {
    let figures: SobraFigures
    let cycle: PayCycle

    var body: some View {
        let chart = PaceChart(cycle: cycle, baseline: figures.baseline, movements: figures.counted,
                              previousCycle: figures.isSobra ? nil : cycle.previous(), previousMovements: figures.previous)
        VStack(alignment: .leading, spacing: 4) {
            Text(figures.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(figures.amount.formattedWhole)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(figures.isSobra && figures.amount.cents < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                if figures.isSobra {
                    StatusChip(text: "\(perDay.formattedWhole)/dia", symbol: "calendar")
                }
                StatusChip(text: daysText, symbol: "hourglass")
            }
            .padding(.top, 4)

            if let caption = figures.caption {
                Label(caption, systemImage: "briefcase")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            chart
                .frame(height: 96)
                .padding(.top, 12)

            status(previousAtSamePoint: chart.previousAtSamePoint)
                .padding(.top, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.cardBackground)
                .overlay(alignment: .top) {
                    // A breath of Garden green at the top of the one hero surface.
                    LinearGradient(colors: [Color.accentColor.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                        .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
                }
        }
    }

    @ViewBuilder
    private func status(previousAtSamePoint: Int64?) -> some View {
        if let baseline = figures.baseline {
            let delta = cycle.paceDelta(spent: figures.spent, of: baseline)
            let ahead = delta > 0.05
            let amount = Money(cents: Int64(abs(delta) * Double(baseline.cents)))
            StatusLine(text: ahead ? "\(amount.formattedWhole) acima do ritmo — vá com calma"
                                   : (delta < -0.05 ? "\(amount.formattedWhole) abaixo do ritmo. Bom trabalho." : "No ritmo certo"),
                       ahead: ahead)
        } else if let before = previousAtSamePoint {
            let difference = Money(cents: figures.spent.cents - before)
            let ahead = difference.cents > 0
            StatusLine(text: difference.cents == 0 ? "Igual ao ciclo anterior até aqui"
                           : "\(difference.magnitude.formattedWhole) \(ahead ? "a mais" : "a menos") que no ciclo anterior até aqui",
                       ahead: ahead)
        } else {
            StatusLine(text: "Defina limites em Categorias para acompanhar o ritmo", ahead: false)
        }
    }

    private var perDay: Money { Money(cents: max(figures.amount.cents, 0) / Int64(cycle.daysRemaining())) }

    private var daysText: String {
        let days = cycle.daysRemaining()
        let payday = cycle.end.formatted(.dateTime.day().month(.abbreviated).locale(Money.brazil))
        return days == 1 ? "1 dia até \(payday)" : "\(days) dias até \(payday)"
    }
}

private struct StatusLine: View {
    let text: String
    let ahead: Bool

    var body: some View {
        Label(text, systemImage: ahead ? "tortoise" : "leaf")
            .font(.footnote.weight(.medium))
            .foregroundStyle(ahead ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
    }
}

extension PayCycle {
    /// Spent fraction vs. elapsed fraction — positive means spending faster than the baseline allows.
    func paceDelta(spent: Money, of baseline: Money, at date: Date = .now) -> Double {
        guard baseline.cents > 0 else { return 0 }
        return Double(spent.cents) / Double(baseline.cents) - elapsedFraction(at: date)
    }
}

struct StatusChip: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.background.opacity(0.7), in: .capsule)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Review card

private struct ReviewCard: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor)
                Text("\(count)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "1 pra conferir" : "\(count) pra conferir")
                    .font(.headline)
                Text("Leva menos de um minuto")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .card()
        .contentShape(.rect)
    }
}

// MARK: - Where the money went (WalletPal-style)

private struct CategoriesCard: View {
    let math: CategoryMath
    let pace: Double
    @Environment(AppRouter.self) private var router

    var body: some View {
        let lines = math.lines
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Para onde foi o dinheiro").font(.headline)
                Spacer()
                Button("Ver todas") { router.tab = .planning }
                    .font(.subheadline)
            }

            HStack(alignment: .center, spacing: 20) {
                SpendingRing(lines: lines, total: math.totalSpent, caption: "no ciclo")
                    .frame(width: 132, height: 132)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lines.prefix(4)) { line in
                        HStack(spacing: 8) {
                            Circle().fill(line.tint.color).frame(width: 8, height: 8)
                            Text(line.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(share(line), format: .percent.precision(.fractionLength(0)))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    if lines.count > 4 {
                        Text("+ \(lines.count - 4) categorias")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            let limited = math.limited.prefix(3)
            if !limited.isEmpty {
                Divider()
                ForEach(Array(limited)) { line in
                    CategoryLineRow(line: line, share: share(line), pace: pace)
                }
            }
        }
        .card()
    }

    private func share(_ line: CategoryMath.Line) -> Double {
        math.totalSpent.cents > 0 ? Double(line.spent.cents) / Double(math.totalSpent.cents) : 0
    }
}

// MARK: - Recent

private struct RecentSection: View {
    let movements: [Movement]
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recentes").font(.headline)
                Spacer()
                Button("Ver tudo") { router.tab = .movements }
                    .font(.subheadline)
            }
            .padding(.bottom, 8)
            ForEach(movements) { movement in
                NavigationLink(value: movement) {
                    MovementRowContent(movement: movement)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                if movement.id != movements.last?.id { Divider().padding(.leading, Theme.rowIconSize + 12) }
            }
        }
        .card()
    }
}

extension String {
    /// "sexta-feira, 3 de outubro" → "Sexta-feira, 3 de outubro"
    var capitalizedSentence: String { prefix(1).uppercased() + dropFirst() }
}

#if DEBUG
#Preview {
    NavigationStack { HomeView() }
        .environment(AppRouter.shared)
        .modelContainer(DemoData.previewContainer)
}
#endif
