import AppIntents
import Charts
import SwiftUI
import WidgetKit

@main
struct GardenWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SobraWidget()
        CategoriesWidget()
        AddMovementControl()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let isPlaceholder: Bool
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .placeholder, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let stored = WidgetSnapshot.load()
        completion(SnapshotEntry(date: .now, snapshot: stored ?? .placeholder, isPlaceholder: stored == nil))
    }

    /// The app reloads timelines whenever its data changes; this only rolls the "dias até o pagamento"
    /// count over at midnight.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let stored = WidgetSnapshot.load()
        let entry = SnapshotEntry(date: .now, snapshot: stored ?? .placeholder, isPlaceholder: stored == nil)
        let calendar = WidgetFormat.calendar
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now.addingTimeInterval(3_600)
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

// MARK: - Sobra do mês

struct SobraWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SobraWidget", provider: SnapshotProvider()) { entry in
            SobraWidgetView(entry: entry)
                .tint(.garden)
                .containerBackground(for: .widget) { WidgetBackground() }
                .widgetURL(URL(string: "garden://home"))
        }
        .configurationDisplayName("Sobra do mês")
        .description("Quanto ainda dá pra gastar até o dia do pagamento.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SobraWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemMedium: medium
        default: small
        }
    }

    // Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(snapshot.title, systemImage: "leaf.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            AmountView(cents: snapshot.amountCents, isOver: snapshot.isOver, size: 30)
            Text(subtitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if snapshot.baselineCents != nil {
                PaceBar(snapshot: snapshot)
                    .padding(.top, 6)
            }
        }
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }

    private var medium: some View {
        HStack(spacing: 16) {
            small
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.categories.prefix(3)) { category in
                    CategoryLine(category: category, total: snapshot.spentCents)
                }
                Spacer(minLength: 0)
                Link(destination: URL(string: "garden://add")!) {
                    Label("Lançar", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.tint.opacity(0.15), in: .capsule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Lock screen

    private var circular: some View {
        Gauge(value: min(snapshot.usedFraction, 1)) {
            Image(systemName: "leaf.fill")
        } currentValueLabel: {
            Text(WidgetFormat.compact(snapshot.amountCents).replacingOccurrences(of: "R$ ", with: ""))
                .minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(snapshot.title, systemImage: "leaf.fill")
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
            Text(WidgetFormat.whole(snapshot.amountCents))
                .font(.headline)
                .monospacedDigit()
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var inline: some View {
        Text(snapshot.isSobra
             ? "\(WidgetFormat.whole(snapshot.perDayCents))/dia · \(snapshot.daysRemaining())d"
             : "\(WidgetFormat.whole(snapshot.spentCents)) no ciclo")
    }

    private var subtitle: String {
        let days = snapshot.daysRemaining()
        let daysText = days == 1 ? "1 dia" : "\(days) dias"
        if snapshot.isOver { return "acima · \(daysText)" }
        return snapshot.isSobra ? "\(WidgetFormat.whole(snapshot.perDayCents))/dia · \(daysText)" : "\(daysText) até o pagamento"
    }
}

// MARK: - Para onde foi o dinheiro

struct CategoriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CategoriesWidget", provider: SnapshotProvider()) { entry in
            CategoriesWidgetView(entry: entry)
                .tint(.garden)
                .containerBackground(for: .widget) { WidgetBackground() }
                .widgetURL(URL(string: "garden://categories"))
        }
        .configurationDisplayName("Para onde foi o dinheiro")
        .description("Gastos do ciclo por categoria e os limites que você definiu.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct CategoriesWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        if family == .systemLarge {
            VStack(alignment: .leading, spacing: 14) {
                header
                HStack(spacing: 16) {
                    ring.frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        AmountView(cents: snapshot.amountCents, isOver: snapshot.isOver, size: 28)
                        if snapshot.baselineCents != nil { PaceBar(snapshot: snapshot) }
                    }
                }
                ForEach(snapshot.categories.prefix(5)) { category in
                    CategoryLine(category: category, total: snapshot.spentCents)
                }
                Spacer(minLength: 0)
            }
            .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        } else {
            HStack(spacing: 16) {
                ring.frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(snapshot.categories.prefix(4)) { category in
                        HStack(spacing: 6) {
                            Circle().fill(color(category.tint)).frame(width: 7, height: 7)
                            Text(category.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(share(category), format: .percent.precision(.fractionLength(0)))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        }
    }

    private var header: some View {
        HStack {
            Text("Para onde foi o dinheiro").font(.headline)
            Spacer()
            Link(destination: URL(string: "garden://add")!) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
        }
    }

    private var ring: some View {
        Chart(snapshot.categories) { category in
            SectorMark(angle: .value("Gasto", Double(category.spentCents)), innerRadius: .ratio(0.68), angularInset: 1.5)
                .foregroundStyle(color(category.tint).gradient)
                .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 0) {
                Text(WidgetFormat.compact(snapshot.spentCents))
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("no ciclo").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    private func share(_ category: WidgetSnapshot.Category) -> Double {
        snapshot.spentCents > 0 ? Double(category.spentCents) / Double(snapshot.spentCents) : 0
    }
}

// MARK: - Control Center: Lançar

struct AddMovementControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "AddMovementControl") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "garden://add")!)) {
                Label("Lançar", systemImage: "plus.circle")
            }
        }
        .displayName("Lançar no Garden")
        .description("Abre o Garden pronto para lançar um gasto.")
    }
}

// MARK: - Pieces

struct WidgetBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color(.secondarySystemGroupedBackground)
            LinearGradient(colors: [Color.garden.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
        }
    }
}

struct AmountView: View {
    let cents: Int64
    let isOver: Bool
    let size: CGFloat

    var body: some View {
        Text(WidgetFormat.whole(cents))
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isOver ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .contentTransition(.numericText())
    }
}

/// Used vs. baseline, with a tick where an even pace would be today.
struct PaceBar: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(snapshot.isAheadOfPace ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint))
                    .frame(width: proxy.size.width * min(snapshot.usedFraction, 1))
                Capsule()
                    .fill(.primary.opacity(0.35))
                    .frame(width: 2, height: 10)
                    .offset(x: proxy.size.width * snapshot.elapsedFraction - 1)
            }
        }
        .frame(height: 6)
    }
}

struct CategoryLine: View {
    let category: WidgetSnapshot.Category
    let total: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color(category.tint))
                    .frame(width: 14)
                Text(category.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(WidgetFormat.whole(category.spentCents))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fraction > 1 ? AnyShapeStyle(Color.red) : AnyShapeStyle(color(category.tint).gradient))
                        .frame(width: proxy.size.width * min(fraction, 1))
                }
            }
            .frame(height: 4)
        }
    }

    /// Against the category limit when there is one, otherwise its share of the cycle.
    private var fraction: Double {
        if let limit = category.limitCents, limit > 0 { return Double(category.spentCents) / Double(limit) }
        return total > 0 ? Double(category.spentCents) / Double(total) : 0
    }
}

extension Color {
    /// The app's accent (AccentColor in this extension's asset catalog): leaf green, lighter in dark mode.
    static let garden = Color("AccentColor")
}

func color(_ tint: String) -> Color {
    switch tint {
    case "green": .green
    case "teal": .teal
    case "blue": .blue
    case "indigo": .indigo
    case "purple": .purple
    case "pink": .pink
    case "red": .red
    case "orange": .orange
    case "yellow": .yellow
    case "brown": .brown
    default: .gray
    }
}
