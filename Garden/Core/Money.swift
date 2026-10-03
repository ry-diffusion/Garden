import Foundation

/// Money is stored as integer centavos. SwiftData persists `Decimal` as a
/// floating-point column, which loses precision (DESIGN §2.7).
struct Money: Hashable, Codable, Comparable, Sendable {
    var cents: Int64
    var currency: String = "BRL"

    static let zero = Money(cents: 0)

    init(cents: Int64, currency: String = "BRL") {
        self.cents = cents
        self.currency = currency
    }

    var decimal: Decimal { Decimal(cents) / 100 }

    static func < (lhs: Money, rhs: Money) -> Bool { lhs.cents < rhs.cents }
    static func + (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents + rhs.cents, currency: lhs.currency) }
    static func - (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents - rhs.cents, currency: lhs.currency) }
    static prefix func - (value: Money) -> Money { Money(cents: -value.cents, currency: value.currency) }

    var magnitude: Money { Money(cents: Swift.abs(cents), currency: currency) }
}

// MARK: - Parsing

extension Money {
    /// Parses Brazilian and plain amounts: "45,90", "1.234,56", "R$ 1.234,56", "45.90", "45".
    init?(parsing text: String, currency: String = "BRL") {
        var s = text
            .replacingOccurrences(of: "R$", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        var negative = false
        if s.hasPrefix("-") || s.hasPrefix("−") {
            negative = true
            s.removeFirst()
        }

        let lastComma = s.lastIndex(of: ",")
        let lastDot = s.lastIndex(of: ".")
        let decimalSeparator: Character?
        switch (lastComma, lastDot) {
        case let (c?, d?): decimalSeparator = c > d ? "," : "."
        case (_?, nil): decimalSeparator = ","
        case let (nil, d?):
            // "1.234" is thousands in pt-BR; "45.90" is a decimal point.
            let digitsAfter = s.distance(from: s.index(after: d), to: s.endIndex)
            decimalSeparator = digitsAfter == 3 ? nil : "."
        case (nil, nil): decimalSeparator = nil
        }

        var integerPart = s
        var fractionPart = ""
        if let sep = decimalSeparator, let idx = s.lastIndex(of: sep) {
            integerPart = String(s[..<idx])
            fractionPart = String(s[s.index(after: idx)...])
        }
        integerPart.removeAll { $0 == "." || $0 == "," }
        guard !integerPart.isEmpty || !fractionPart.isEmpty,
              integerPart.allSatisfy(\.isNumber), fractionPart.allSatisfy(\.isNumber),
              fractionPart.count <= 2
        else { return nil }

        let whole = Int64(integerPart.isEmpty ? "0" : integerPart) ?? 0
        let fraction = Int64(fractionPart.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        let cents = whole * 100 + fraction
        self.init(cents: negative ? -cents : cents, currency: currency)
    }
}

// MARK: - Formatting

extension Money {
    static let brazil = Locale(identifier: "pt_BR")

    /// "R$ 1.234,56"
    var formatted: String {
        decimal.formatted(.currency(code: currency).locale(Self.brazil))
    }

    /// "R$ 1.234" — drops centavos for headline numbers.
    var formattedWhole: String {
        decimal.formatted(.currency(code: currency).locale(Self.brazil).precision(.fractionLength(0)))
    }

    /// "R$ 1,2 mil" — compact for widgets and chips.
    var formattedCompact: String {
        guard Swift.abs(cents) >= 1_000_000 else { return formattedWhole }
        let compact = decimal.formatted(.number.notation(.compactName).locale(Self.brazil).precision(.fractionLength(0...1)))
        return "R$ \(compact)"
    }
}
