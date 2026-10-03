import Foundation

/// What the widgets show, written by the app to the shared App Group whenever the ledger or the
/// Sobra settings change. The widget never opens the SwiftData store: it only reads this.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    struct Category: Codable, Sendable, Equatable, Identifiable {
        var key: String
        var name: String
        var symbol: String
        var tint: String
        var spentCents: Int64
        var limitCents: Int64?
        var id: String { key }
    }

    var updatedAt: Date
    /// "Sobra do mês" or "Gasto no ciclo".
    var title: String
    var amountCents: Int64
    /// True when `amountCents` is what's left (cap, salary or category limits); false when it's what was spent.
    var isSobra: Bool
    /// Cap, expected income or sum of limits — what the spending is measured against.
    var baselineCents: Int64?
    var spentCents: Int64
    var caption: String?
    var cycleStart: Date
    var cycleEnd: Date
    /// Biggest spending first.
    var categories: [Category]

    static let appGroup = "group.br.com.zesmoi.Garden"
    private static let key = "widgetSnapshot"

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes only when something changed. Returns whether it wrote.
    @discardableResult
    func save() -> Bool {
        guard let defaults = UserDefaults(suiteName: Self.appGroup),
              let data = try? JSONEncoder().encode(self)
        else { return false }
        if let current = defaults.data(forKey: Self.key),
           var previous = try? JSONDecoder().decode(WidgetSnapshot.self, from: current) {
            previous.updatedAt = updatedAt
            if previous == self { return false }
        }
        defaults.set(data, forKey: Self.key)
        return true
    }

    // MARK: Derived

    func daysRemaining(from date: Date = .now) -> Int {
        let calendar = WidgetFormat.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: cycleEnd).day ?? 1
        return max(days, 1)
    }

    var perDayCents: Int64 { isSobra ? max(amountCents, 0) / Int64(daysRemaining()) : 0 }

    /// Spent / baseline, 0…1+.
    var usedFraction: Double {
        guard let baseline = baselineCents, baseline > 0 else { return 0 }
        return Double(spentCents) / Double(baseline)
    }

    var elapsedFraction: Double {
        let total = cycleEnd.timeIntervalSince(cycleStart)
        guard total > 0 else { return 0 }
        return min(max(Date.now.timeIntervalSince(cycleStart) / total, 0), 1)
    }

    var isOver: Bool { isSobra && amountCents < 0 }
    var isAheadOfPace: Bool { isOver || (baselineCents != nil && usedFraction > elapsedFraction + 0.05) }

    static let placeholder = WidgetSnapshot(
        updatedAt: .now, title: "Sobra do mês", amountCents: 184_000, isSobra: true, baselineCents: 500_000, spentCents: 316_000,
        caption: nil, cycleStart: .now.addingTimeInterval(-18 * 86_400), cycleEnd: .now.addingTimeInterval(12 * 86_400),
        categories: [
            .init(key: "mercado", name: "Mercado", symbol: "cart", tint: "green", spentCents: 109_000, limitCents: 140_000),
            .init(key: "comer-fora", name: "Comer fora", symbol: "fork.knife", tint: "orange", spentCents: 45_000, limitCents: 60_000),
            .init(key: "transporte", name: "Transporte", symbol: "car", tint: "blue", spentCents: 27_300, limitCents: nil),
            .init(key: "lazer", name: "Lazer", symbol: "theatermasks", tint: "purple", spentCents: 13_200, limitCents: nil),
        ]
    )
}

enum WidgetFormat {
    static let locale = Locale(identifier: "pt_BR")

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo") ?? .current
        return calendar
    }()

    /// "R$ 1.840"
    static func whole(_ cents: Int64) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "BRL").locale(locale).precision(.fractionLength(0)))
    }

    /// "R$ 1,8 mil" for tight spots.
    static func compact(_ cents: Int64) -> String {
        guard abs(cents) >= 1_000_000 else { return whole(cents) }
        let value = (Decimal(cents) / 100).formatted(.number.notation(.compactName).locale(locale).precision(.fractionLength(0...1)))
        return "R$ \(value)"
    }
}
