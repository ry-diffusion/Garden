import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Keeps the widgets' snapshot current: recomputes it (debounced) after every save to the store and
/// after the Sobra settings change, writes it to the App Group, and reloads the widget timelines.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in WidgetPublisher.shared.schedule() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { _ in
            Task { @MainActor in WidgetPublisher.shared.schedule() }
        })
        schedule(after: .zero)
    }

    func schedule(after delay: Duration = .seconds(1)) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            publish()
        }
    }

    func publish() {
        let context = GardenStore.shared.mainContext
        let defaults = UserDefaults.standard
        let cycle = Preferences.currentCycle
        let mode = SobraMode(rawValue: defaults.string(forKey: Preferences.sobraModeKey) ?? "") ?? .plan
        let capCents = defaults.integer(forKey: Preferences.monthlyCapKey)

        let start = cycle.start, end = cycle.end
        let previous = cycle.previous()
        let previousStart = previous.start, previousEnd = previous.end
        let movements = (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        let previousMovements = (try? context.fetch(FetchDescriptor<Movement>(
            predicate: #Predicate { $0.date >= previousStart && $0.date < previousEnd }))) ?? []
        let categories = (try? context.fetch(FetchDescriptor<SpendCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []

        let math = CategoryMath(cycle: cycle, categories: categories, movements: movements)
        let figures = SobraFigures.make(math: math, cycle: cycle, mode: mode, capCents: capCents,
                                        previousMovements: previousMovements, context: context)
        let snapshot = WidgetSnapshot(
            updatedAt: .now,
            title: figures.title,
            amountCents: figures.amount.cents,
            isSobra: figures.isSobra,
            baselineCents: figures.baseline?.cents,
            spentCents: math.totalSpent.cents,
            caption: figures.caption,
            cycleStart: cycle.start,
            cycleEnd: cycle.end,
            categories: math.lines.prefix(6).map { line in
                WidgetSnapshot.Category(key: line.id, name: line.name, symbol: line.symbol, tint: line.tint.rawValue,
                                        spentCents: line.spent.cents, limitCents: line.limit?.cents)
            }
        )
        guard snapshot.save() else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
