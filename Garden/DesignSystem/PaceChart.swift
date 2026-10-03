import Charts
import SwiftUI

/// Cumulative spending across the pay cycle. The dashed reference is either the even-pace line toward a
/// baseline (limits or income), or — with no baseline — the previous cycle's spending at the same point.
struct PaceChart: View {
    struct Point: Identifiable {
        let date: Date
        let cents: Int64
        var id: Date { date }
    }

    let cycle: PayCycle
    let baseline: Money?
    let points: [Point]
    let previous: [Point]

    init(cycle: PayCycle, baseline: Money?, movements: [Movement], previousCycle: PayCycle? = nil,
         previousMovements: [Movement] = [], now: Date = .now) {
        self.cycle = cycle
        self.baseline = (baseline?.cents ?? 0) > 0 ? baseline : nil
        self.points = Self.cumulative(movements, in: cycle, until: now, shiftedTo: nil)
        if let previousCycle {
            self.previous = Self.cumulative(previousMovements, in: previousCycle, until: previousCycle.end, shiftedTo: cycle)
        } else {
            self.previous = []
        }
    }

    /// Running total per day. `shiftedTo` maps another cycle's days onto this one, for comparison.
    private static func cumulative(_ movements: [Movement], in cycle: PayCycle, until end: Date, shiftedTo target: PayCycle?) -> [Point] {
        let calendar = Calendar.brazil
        let byDay = Dictionary(grouping: movements) { calendar.startOfDay(for: $0.date) }
        let offset = target.map { $0.start.timeIntervalSince(cycle.start) } ?? 0
        var running: Int64 = 0
        var points = [Point(date: cycle.start.addingTimeInterval(offset), cents: 0)]
        var day = calendar.startOfDay(for: cycle.start)
        let last = calendar.startOfDay(for: min(end, cycle.end))
        while day <= last && day < cycle.end {
            running += (byDay[day] ?? []).reduce(0) { $0 + $1.netCost.magnitude.cents }
            let next = min(calendar.date(byAdding: .day, value: 1, to: day) ?? day, end)
            points.append(Point(date: next.addingTimeInterval(offset), cents: running))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? cycle.end
        }
        return points
    }

    private var spent: Int64 { points.last?.cents ?? 0 }

    /// Where the comparison stood at this same moment of its cycle.
    var previousAtSamePoint: Int64? {
        guard let now = points.last?.date, !previous.isEmpty else { return nil }
        return previous.last { $0.date <= now }?.cents
    }

    private var isAhead: Bool {
        if let baseline, let last = points.last {
            return Double(spent) > Double(baseline.cents) * cycle.elapsedFraction(at: last.date) * 1.05
        }
        if let before = previousAtSamePoint { return Double(spent) > Double(before) * 1.05 }
        return false
    }

    var body: some View {
        let tint: Color = isAhead ? .orange : .accentColor
        let ceiling = max(Double(baseline?.cents ?? 0), Double(spent), Double(previous.last?.cents ?? 0), 1) / 100 * 1.08
        Chart {
            if let baseline {
                ForEach([(cycle.start, 0.0), (cycle.end, Double(baseline.cents) / 100)], id: \.0) { date, value in
                    LineMark(x: .value("Dia", date), y: .value("Valor", value), series: .value("Série", "ideal"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            } else {
                ForEach(previous) { point in
                    LineMark(x: .value("Dia", point.date), y: .value("Valor", Double(point.cents) / 100), series: .value("Série", "anterior"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .interpolationMethod(.monotone)
                }
            }

            ForEach(points) { point in
                AreaMark(x: .value("Dia", point.date), y: .value("Gasto", Double(point.cents) / 100))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Dia", point.date), y: .value("Gasto", Double(point.cents) / 100),
                         series: .value("Série", "real"))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = points.last {
                PointMark(x: .value("Dia", last.date), y: .value("Gasto", Double(last.cents) / 100))
                    .foregroundStyle(tint)
                    .symbolSize(60)
            }
        }
        .chartXScale(domain: cycle.start...cycle.end)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityElement()
        .accessibilityLabel("Ritmo de gastos")
        .accessibilityValue(isAhead ? "Acima do ritmo" : "Dentro do ritmo")
    }
}

/// WalletPal-style segmented ring: each category's share of the cycle's spending.
struct SpendingRing: View {
    let lines: [CategoryMath.Line]
    let total: Money
    var caption: LocalizedStringKey = "gasto no ciclo"

    var body: some View {
        Chart(lines) { line in
            SectorMark(angle: .value("Gasto", Double(line.spent.cents)), innerRadius: .ratio(0.7), angularInset: 1.5)
                .foregroundStyle(line.tint.color.gradient)
                .cornerRadius(4)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 2) {
                Text(total.formattedWhole)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .accessibilityElement()
        .accessibilityLabel("Gastos por categoria")
        .accessibilityValue(lines.prefix(3).map { "\($0.name) \($0.spent.formattedWhole)" }.joined(separator: ", "))
    }
}
