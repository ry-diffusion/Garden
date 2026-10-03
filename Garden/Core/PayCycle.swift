import Foundation

/// A budgeting month that starts on payday instead of the 1st (DESIGN §7).
/// With payday = 5, the cycle containing Oct 3 is Sep 5 ..< Oct 5.
struct PayCycle: Hashable, Sendable {
    let start: Date
    let end: Date  // exclusive

    static let defaultPayday = 5

    init(containing date: Date = .now, payday: Int = PayCycle.defaultPayday, calendar: Calendar = .brazil) {
        let day = min(max(payday, 1), 28)
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = day
        let thisMonthsPayday = calendar.date(from: components) ?? date
        let start = date >= thisMonthsPayday
            ? thisMonthsPayday
            : calendar.date(byAdding: .month, value: -1, to: thisMonthsPayday) ?? thisMonthsPayday
        self.start = start
        self.end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
    }

    var interval: DateInterval { DateInterval(start: start, end: end) }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Days left including today, never below 1.
    func daysRemaining(from date: Date = .now, calendar: Calendar = .brazil) -> Int {
        let today = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: end).day ?? 1
        return max(days, 1)
    }

    /// Fraction of the cycle elapsed, 0...1, used for the pace line.
    func elapsedFraction(at date: Date = .now) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / total, 0), 1)
    }

    func previous(calendar: Calendar = .brazil) -> PayCycle {
        PayCycle(containing: calendar.date(byAdding: .day, value: -1, to: start) ?? start,
                 payday: calendar.component(.day, from: start), calendar: calendar)
    }
}

extension Calendar {
    static let brazil: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "pt_BR")
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo") ?? .current
        return calendar
    }()
}
